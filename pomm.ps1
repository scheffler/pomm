#
# Migration builder which compiles a single consolidated migration script for each database.
# The builder expects there to be a separate subdirectory for each database, where the folder name
# matches the name of the database to be created/updated.  Within each database folder, create separate 
# SQL files for each block of database updates which are needed over time.  The files should follow this
# naming convention
#
#		1.2.3-Name.sql
#
# A 3 part migration number scheme is used to allow for major, minor, and patch migrations.  
#
# Each SQL file will be treated as a separate migration block and will be wrapped in "IF NOT EXISTS" logic to ensure
# that the migrations are never applied more than once to an environment.  A _Migrations table is created within each database
# which stores the history of which migrations have been applied.  
#

$namematch = "^(?<migname>((?<major>\d*?)\.(?<minor>\d*?)\.(?<sub>\d*?))-(.*))\.sql$"
$thematcher = New-Object System.Text.RegularExpressions.Regex($namematch, [System.Text.RegularExpressions.RegexOptions]::Compiled)
$basedir = Split-Path $MyInvocation.MyCommand.Path
$dbnames = dir "$basedir\migrations\" | Where-Object { $_.PSIsContainer } 
$destdir = "$basedir\deploy"
$dbserver = "localhost" 

if (!(Test-Path $destdir)){ New-Item $destdir -ItemType directory | Out-Null }

$gomatch = "^\W*GO\W*$"
$gomatcher = New-Object System.Text.RegularExpressions.Regex($gomatch, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)


#
# Given a block of sql, scan to see if there are any GO statements.
# Return an array of sql blocks which can then be wrapped in separate
# Exec statements
#
function SeparateOnGo($sql) 
{
	$anarray = @()
	$sb = New-Object System.Text.StringBuilder
	foreach($line in $sql) {
		$found = $gomatcher.Match("$line")
		if ($found.Success) {
			$anarray += ,($sb.ToString())
			$sb = New-Object System.Text.StringBuilder
			continue
		}
		$sb.AppendLine($line) | Out-Null
	}
	$anarray += ,($sb.ToString())
	return [String[]]$anarray
}

function MigrationCheckBeginPlusBlock($migname, $block, $printapply) 
{
	$sb = New-Object System.Text.StringBuilder
	$sb.AppendLine("IF NOT EXISTS (SELECT * FROM _Migrations WHERE Name = '$migname')") | Out-Null
	$sb.AppendLine("BEGIN`r`n") | Out-Null
	if ($printapply) {
		$sb.AppendLine("print 'Applying migration $migname'") | Out-Null
	}
	$sb.AppendLine($block) | Out-Null
	return $sb.ToString()
}

function MigrationCompleteStatement($migname) 
{
	return "INSERT _Migrations SELECT '$migname', GETDATE()"
}

function WrapInIfObjectNotExistsStatement($objectname, $block) 
{
	$sb = New-Object System.Text.StringBuilder
	$sb.AppendLine("IF NOT EXISTS (SELECT null FROM sys.all_objects WHERE name = '$objectname')")  | Out-Null
	$sb.AppendLine('BEGIN') | Out-Null
	$sb.AppendLine($block) | Out-Null
	$sb.AppendLine("END`r`n") | Out-Null
	return $sb.ToString()
}

function WrapInMigrationExistsCheck($migname, $block) 
{
	$sb = New-Object System.Text.StringBuilder
	$sb.AppendLine("IF NOT EXISTS (SELECT * FROM _Migrations WHERE Name = '$migname')") | Out-Null
	$sb.AppendLine('BEGIN') | Out-Null
	$sb.AppendLine($block) | Out-Null
	$sb.AppendLine("END`r`n") | Out-Null
	return $sb.ToString()
}

function MigrationsTableBuilderStatement() 
{
	$tbl = "PRINT 'Creating_Migrations table'`r`n"
	$tbl += "CREATE TABLE _Migrations (`r`n"
	$tbl += "`tName NVARCHAR(256) NOT NULL,`r`n"
	$tbl +=	"`tDateApplied DATETIME NOT NULL`r`n)"
	return WrapInIfObjectNotExistsStatement "_Migrations" $tbl
}

function CreateDatabaseStatement($dbname) 
{
	$sql = "IF NOT EXISTS ( SELECT * FROM [master].[dbo].[sysdatabases] sdt WHERE sdt.[name] = '$dbname' )`r`n"
	$sql += "BEGIN`r`n`tCREATE DATABASE [$dbname]`r`nEND`r`nGO`r`n"
	$sql += "`r`nUSE [$dbname]`r`nGO`r`nSET QUOTED_IDENTIFIER OFF`r`nGO`r`n"
	return $sql
}

#
# Hash the migration files based on the version number in the filename
#
function BuildMigrationFileHash($adb) {
	$migtable = @{}
	$thedir = $adb.FullName
	$migfiles = Get-ChildItem -Path "$thedir\*" -Include "*.sql"
	$lastobj = ""
	foreach ($afile in $migfiles) {
		$thename = $afile.Name
		$match = $thematcher.Match("$thename")
		if (!$match.Success) {
			Write-Host "Invalid migration file version format encountered: ", $afile.Name
			exit 1
		}
		$major = [int]($match.Groups["major"].Value) * 100000
		$minor = [int]($match.Groups["minor"].Value)
		$sub = [int]($match.Groups["sub"].Value) / 1000
		$versionhash = $major + $minor + $sub
		$lastobj = $match.Groups[1].Value, $match.Groups["migname"].Value, $afile.FullName
		$migtable[$versionhash] = $lastobj
	}
	return [array]($migtable.GetEnumerator() | Sort-Object Name)
}

function ProcessSqlFile($migname, $sql)
{
	$goblocks = [String[]](SeparateOnGo $sql)
	$gocount = $goblocks.Length
	$sb = New-Object System.Text.StringBuilder
	if ($gocount -eq 1) {
		$singlesql = MigrationCheckBeginPlusBlock $migname ($goblocks[0]) $true
		$sb.AppendLine($singlesql) | Out-Null
	} else {
		for($i = 0; ($i -lt $gocount) ; $i++) {
			$sb.AppendLine( (MigrationCheckBeginPlusBlock $migname ($goblocks[$i])($i -eq 0)) ) | Out-Null
			if ($i -lt ($gocount - 1) ) {
				$sb.AppendLine( "END`r`n" ) | Out-Null
				$sb.AppendLine("`r`nGO`r`n") | Out-Null
			}
		}
	}
	$sb.AppendLine( (MigrationCompleteStatement $migname) ) | Out-Null
	$sb.AppendLine( "END`r`n" ) | Out-Null
	return $sb.ToString()
}

#
# MAIN block
#
foreach($adbname in $dbnames) {
	$migrations = [array](BuildMigrationFileHash $adbname)
	# TODO TRANSACTION WRAPPER?
	$thefile = New-Object System.Text.StringBuilder
	$thefile.AppendLine( (CreateDatabaseStatement $adbname) ) | Out-Null
	$thefile.AppendLine( (MigrationsTableBuilderStatement) ) | Out-Null
	$thefile.AppendLine("GO") | Out-Null

	for($i = 0; $i -lt $migrations.Length; $i++) {
		$migfile = $migrations[$i]
		$sqlcontent = Get-Content ($migfile.Value[2])
		$block = ProcessSqlFile ($migfile.Value[1]) ($sqlcontent)
		$thefile.AppendLine($block) | Out-Null
		if (! ($i -eq ($migrations.Length - 1))) {
			$thefile.AppendLine("GO`r`n") | Out-Null
		}
	}

	New-Item -Path $destdir -Name "$adbname-migrations.sql" -type file -Value ($thefile.ToString()) -Force | Out-Null
	Write-Host "Migration file created at $destdir\$adbname-migrations.sql"
}



# TODO alternately - if there's a 0-migration, then use that to create the database





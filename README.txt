The migration manager is convention based and is expecting to find a separate subdirectory
here for each database.  The name of the folder should match the database name.  

Within each database folder, create separate 
SQL files for each block of database updates which are needed over time.  The files should follow this
naming convention
		1.2.3-Name.sql

A 3 part migration number scheme is used to allow for major, minor, and patch migrations.  

Each SQL file will be treated as a separate migration block and will be wrapped in "IF NOT EXISTS" logic to ensure
that the migrations are never applied more than once to an environment.  A _Migrations table is created within each database
which stores the history of which migrations have been applied.  

Licensed under the MIT license.  See details in LICENSE.txt.

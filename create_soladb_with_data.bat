@echo off

set psql_path=%~dp0
set psql_path="%psql_path%psql\psql.exe"
set host=localhost
set dbname=sola

set username=postgres
set password=?

set createDB=NO

set /p host= Host name [%host%] :

set /p dbname= Database name [%dbname%] :

set /p username= Username [postgres] :

set /p password= Password [%password%] :


CHOICE /T 10 /C yn /CS /D n /M "Create DB? [n] "


IF %ERRORLEVEL%==1 (

set createDB=YES
)ELSE (
set createDB=NO
)

echo
echo
echo Starting Build at %time%
echo Starting Build at %time% > build.log 2>&1

IF %createDB%==YES (
echo Creating database...
echo Creating database... >> build.log 2>&1
%psql_path% --host=%host% --port=5432 --username=%username% %password% --dbname=%dbname% --command="create database %dbname% with encoding='UTF8' template=postgistemplate connection limit=-1;" >> build.log 2>&1
)

echo Running sola.sql...
echo Running sola.sql... >> build.log 2>&1
%psql_path% --host=%host% --port=5432 --username=%username% --dbname=%dbname% --file=sola.sql >> build.log 2>&1
%psql_path% --host=%host% --port=5432 --username=%username% --dbname=%dbname% --file=testdata.sql >> build.log 2>&1

echo Loading business rules...
echo Loading business rules... >> build.log 2>&1
%psql_path% --host=%host% --port=5432 --username=%username% --dbname=%dbname% --file=business_rules.sql >> build.log 2>&1

echo Loading Nepali calendar...
echo Loading Nepali calendar... >> build.log 2>&1
%psql_path% --host=%host% --port=5432 --username=%username% --dbname=%dbname% --file=nep_calendar.sql >> build.log 2>&1

echo SRID insert...
echo SRID insert... >> build.log 2>&1
%psql_path% --host=%host% --port=5432 --username=%username% --dbname=%dbname% --file=srid_insert.sql >> build.log 2>&1

echo Loading Mulpani spatial data...
echo Loading Mulpani spatial data... >> build.log 2>&1
%psql_path% --host=%host% --port=5432 --username=%username% --dbname=%dbname% --file=sola_populate_mulpani_sample.sql >> build.log 2>&1

echo Updating extent...
echo Updating extent... >> build.log 2>&1
%psql_path% --host=%host% --port=5432 --username=%username% --dbname=%dbname% --file=update_min_max_Extents.sql >> build.log 2>&1

echo Finished at %time% - Check build.log for errors!
echo Finished at %time% >> build.log 2>&1
pause
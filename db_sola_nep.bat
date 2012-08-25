set host=localhost
set psql_path=psql\
set script_folder=
set dbname=sola
set pw=
set extra_options=--single-transaction --quiet -v ON_ERROR_STOP=1
%psql_path%psql %extra_options% --host=%host% --port=5432 --username=postgres --password=%pw% --dbname=%dbname% --file=%script_folder%sola.sql
%psql_path%psql %extra_options% --host=%host% --port=5432 --username=postgres --password=%pw% --dbname=%dbname% --file=%script_folder%testdata.sql
%psql_path%psql %extra_options% --host=%host% --port=5432 --username=postgres --password=%pw% --dbname=%dbname% --file=%script_folder%business_rules.sql
%psql_path%psql %extra_options% --host=%host% --port=5432 --username=postgres --password=%pw% --dbname=%dbname% --file=%script_folder%nep_calendar.sql
%psql_path%psql %extra_options% --host=%host% --port=5432 --username=postgres --password=%pw% --dbname=%dbname% --file=%script_folder%srid_insert.sql
%psql_path%psql %extra_options% --host=%host% --port=5432 --username=postgres --password=%pw% --dbname=%dbname% --file=%script_folder%sola_populate_mulpani_sample.sql
%psql_path%psql %extra_options% --host=%host% --port=5432 --username=postgres --password=%pw% --dbname=%dbname% --file=%script_folder%update_min_max_Extents.sql
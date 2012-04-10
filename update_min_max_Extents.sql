DROP SCHEMA IF EXISTS test_etl1 CASCADE;
CREATE SCHEMA test_etl1;

--parcel data table import.
CREATE OR REPLACE FUNCTION sola.test_etl1.set_extents() RETURNS varchar
 AS
$BODY$
DECLARE 
    rec record;
BEGIN
	FOR rec IN EXECUTE 'SELECT min(xmin(the_geom)) as x_min,max(xmax(the_geom)) as x_max,
		 min(ymin(the_geom)) as y_min,max(ymax(the_geom)) as y_max
		 FROM sola.testdata.mulpani_parcel WHERE (ST_GeometryN(the_geom, 1) IS NOT NULL)'
	LOOP
		update sola.system.setting set vl=rec.x_min where "name"='map-west';
		update sola.system.setting set vl=rec.x_max where "name"='map-east';
		update sola.system.setting set vl=rec.y_min where "name"='map-south';
		update sola.system.setting set vl=rec.y_max where "name"='map-north';
		update sola.system.setting set vl=97261 where "name"='map-srid';
	END LOOP;
	
    RETURN 'ok';
END;

$BODY$
  LANGUAGE plpgsql;
  
--execute update procedure.
  SELECT sola.test_etl1.set_extents();
  
 DROP SCHEMA IF EXISTS test_etl1 CASCADE;
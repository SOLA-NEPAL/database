DROP SCHEMA IF EXISTS test_etl1 CASCADE;
CREATE SCHEMA test_etl1;

--parcel data table import.
CREATE OR REPLACE FUNCTION test_etl1.set_extents() RETURNS varchar
 AS
$BODY$
DECLARE 
    rec record;
BEGIN
	FOR rec IN EXECUTE 'SELECT min(xmin(geom_polygon)) as x_min,max(xmax(geom_polygon)) as x_max,
		 min(ymin(geom_polygon)) as y_min,max(ymax(geom_polygon)) as y_max
		 FROM cadastre.cadastre_object WHERE (geom_polygon IS NOT NULL)'
	LOOP
		update system.setting set vl=rec.x_min where "name"='map-west';
		update system.setting set vl=rec.x_max where "name"='map-east';
		update system.setting set vl=rec.y_min where "name"='map-south';
		update system.setting set vl=rec.y_max where "name"='map-north';
		update system.setting set vl=97261 where "name"='map-srid';
	END LOOP;
	
    RETURN 'ok';
END;

$BODY$
  LANGUAGE plpgsql;
  
--execute update procedure.
  SELECT test_etl1.set_extents();
  
 DROP SCHEMA IF EXISTS test_etl1 CASCADE;
--TO POPULATE THE SOLA DATABASE WITH LINZ DATA for Bhaktpur district (FROM SHAPEFILES)
--INTO LADM RELATED TABLES
DROP SCHEMA IF EXISTS test_etl CASCADE;
CREATE SCHEMA test_etl;

--parcel data table import.
CREATE OR REPLACE FUNCTION sola.test_etl.load_parcel() RETURNS varchar
 AS
$BODY$
DECLARE 
    rec record;
    transaction_id_vl varchar;
BEGIN
    transaction_id_vl = 'cadastre-transaction';
    delete from sola.transaction.transaction where id = transaction_id_vl;
    insert into sola.transaction.transaction(id, status_code, approval_datetime, change_user) values(transaction_id_vl, 'approved', now(), 'test-id');

	FOR rec IN EXECUTE 'SELECT gid, parcelno, district, vdc, wardno, grids1,parcelty,
		ST_GeometryN(the_geom, 1) AS the_geom,''current'' AS parcel_status FROM sola.testdata."mulpani_parcel" WHERE (ST_GeometryN(the_geom, 1) IS NOT NULL)'
	LOOP
		INSERT INTO sola.cadastre.cadastre_object (id, transaction_id, parcel_no, district, vdc, wardno, grids1,parcel_type,geom_polygon,status_code
		,name_firstpart,name_lastpart)
		VALUES (rec.gid, transaction_id_vl, rec.parcelno, rec.district, rec.vdc,rec.wardno, rec.grids1,rec.parcelty,rec.the_geom, rec.parcel_status,'test','test');  
	END LOOP;
	
    RETURN 'ok';
END;
$BODY$
  LANGUAGE plpgsql;

  --construction data table import.
  CREATE OR REPLACE FUNCTION sola.test_etl.load_construction() RETURNS varchar
 AS
$BODY$
DECLARE 
    rec record;
BEGIN
	FOR rec IN EXECUTE 'SELECT gid,parfid, consty, shape_leng, shape_area,
		ST_GeometryN(the_geom, 1) AS the_geom FROM sola.testdata."mulpani_construction" WHERE (ST_GeometryN(the_geom, 1) IS NOT NULL)'
	LOOP
		INSERT INTO sola.cadastre.construction (cid, id, constype, area,geom_polygon)
			VALUES (rec.gid, rec.parfid, rec.consty, rec.shape_area, rec.the_geom);  
	END LOOP;
	
    RETURN 'ok';
END;
$BODY$
  LANGUAGE plpgsql;
  


--INSERT VALUES FOR THE PARCELS
delete from sola.cadastre.level;
INSERT INTO sola.cadastre.level (id, name, register_type_code, structure_code, type_code, change_user)
                VALUES (uuid_generate_v1(), 'Parcels', 'all', 'polygon', 'primaryRight', 'test');

				--remove any existing Test Data
delete from sola.cadastre.spatial_unit;
INSERT INTO sola.cadastre.spatial_unit (id, dimension_code, label, surface_relation_code, level_id, change_user) 
	SELECT gid, '2D', ' ', 'onSurface',  
	(SELECT id FROM sola.cadastre.level WHERE name='Parcels') As l_id, 'test' AS ch_user
	FROM sola.testdata."mulpani_parcel" WHERE ST_GeometryN(the_geom, 1) IS NOT NULL;

	--execute function to execute shapes.
delete from sola.cadastre.cadastre_object;
SELECT sola.test_etl.load_parcel();
delete from sola.cadastre.construction;
SELECT sola.test_etl.load_construction();

UPDATE sola.cadastre.spatial_unit SET level_id = (SELECT id FROM cadastre.level WHERE name = 'Parcels') 
			WHERE (level_id IS NULL);

INSERT INTO sola.cadastre.spatial_value_area (spatial_unit_id, type_code, size, change_user)
	SELECT 	gid, 'officialArea', shape_area, 'test' AS ch_user FROM sola.testdata."mulpani_parcel";

INSERT INTO sola.cadastre.spatial_value_area (spatial_unit_id, type_code, size, change_user)
	SELECT 	id, 'calculatedArea', st_area(geom_polygon), 'test' AS ch_user FROM sola.cadastre.cadastre_object;


INSERT INTO sola.source.archive (id, name, change_user) VALUES ('archive-id', 'Land Information mulpani', 'test'); 

INSERT INTO sola.source.source (id, archive_id, la_nr, submission, maintype, type_code, content, availability_status_code, change_user)
VALUES (uuid_generate_v1(), 'archive-id', 'Landonline', '2012-04-05', 'mapDigital', 'cadastralMap', 'Land Information Mulpani', 'available', 'test');

-- enable triggers in the database
--select fn_triggerall(true);

--COMMIT;

DROP SCHEMA IF EXISTS test_etl CASCADE;
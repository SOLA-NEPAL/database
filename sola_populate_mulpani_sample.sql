--TO POPULATE THE SOLA DATABASE WITH LINZ DATA for Bhaktpur district (FROM SHAPEFILES)
--INTO LADM RELATED TABLES
DROP SCHEMA IF EXISTS test_etl CASCADE;
CREATE SCHEMA test_etl;

--parcel data table import.
CREATE OR REPLACE FUNCTION test_etl.load_parcel() RETURNS varchar
 AS
$BODY$
DECLARE 
    rec record;
    rec1 record;
    rec2 record;
    transaction_id_vl varchar;
	address_id_vl varchar;
BEGIN
    transaction_id_vl = 'cadastre-transaction';
    delete from transaction.transaction where id = transaction_id_vl;
    insert into transaction.transaction(id, status_code, approval_datetime, change_user) values(transaction_id_vl, 'approved', now(), 'test-id');

	FOR rec1 IN EXECUTE 'SELECT district,wardno,vdc FROM testdata."mulpani_parcel" WHERE (ST_GeometryN(the_geom, 1) IS NOT NULL)'
	LOOP
		 address_id_vl=cast(rec1.district as text) || '-' || cast(rec1.vdc as text) || '-' || cast(rec1.wardno as text);
		 INSERT INTO address.address (id, vdc_code, ward_no) 
					VALUES (address_id_vl, cast(27009 as text) , cast(rec1.wardno as text)); 
		 exit;
	END LOOP;
	
	FOR rec2 IN EXECUTE 'SELECT distinct grids1 FROM testdata."mulpani_parcel" WHERE (ST_GeometryN(the_geom, 1) IS NOT NULL)'
	LOOP
		 INSERT INTO cadastre.map_sheet (id, map_number,sheet_type,office_code,srid) 
					VALUES (rec2.grids1, rec2.grids1,0,'7-25-003-001',97261); 
	END LOOP;
	
	FOR rec IN EXECUTE 'SELECT gid, objectid, parcelno, district,wardno,vdc, grids1,parcelty,
		ST_GeometryN(the_geom, 1) AS the_geom,''current'' AS parcel_status FROM testdata."mulpani_parcel" WHERE (ST_GeometryN(the_geom, 1) IS NOT NULL)'
	LOOP
		INSERT INTO cadastre.cadastre_object (id, transaction_id, parcel_no, land_use_code,geom_polygon,map_sheet_id,status_code,name_firstpart,name_lastpart, office_code, fy_code)
		VALUES (rec.gid, transaction_id_vl, rec.parcelno,rec.parcelty,rec.the_geom, rec.grids1, rec.parcel_status
		,cast(rec.district as text) || '-' || cast(rec.vdc as text) || '-' || cast(rec.wardno as text),rec.parcelno, '7-25-003-001', 'y1');

	END LOOP;
	
    RETURN 'ok';
END;
$BODY$
  LANGUAGE plpgsql;

  --construction data table import.
  CREATE OR REPLACE FUNCTION test_etl.load_construction() RETURNS varchar
 AS
$BODY$
DECLARE 
    rec record;
BEGIN
	FOR rec IN EXECUTE 'SELECT gid,parfid, consty, shape_leng, shape_area,
		ST_GeometryN(the_geom, 1) AS the_geom FROM testdata."mulpani_construction" WHERE (ST_GeometryN(the_geom, 1) IS NOT NULL)'
	LOOP
		INSERT INTO cadastre.construction (cid, id, constype, area,geom_polygon)
			VALUES (rec.gid, rec.parfid, rec.consty, rec.shape_area, rec.the_geom);  
	END LOOP;
	
    RETURN 'ok';
END;
$BODY$
  LANGUAGE plpgsql;
  
	--execute function to execute shapes.
delete from cadastre.cadastre_object;
SELECT test_etl.load_parcel();
delete from cadastre.construction;
SELECT test_etl.load_construction();



--COMMIT;

DROP SCHEMA IF EXISTS test_etl CASCADE;
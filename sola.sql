
-- Starting up the database script generation
ALTER DATABASE sola SET bytea_output TO 'escape';
    
--Create schema source--
DROP SCHEMA IF EXISTS source CASCADE;
        
CREATE SCHEMA source;

--Create schema party--
DROP SCHEMA IF EXISTS party CASCADE;
        
CREATE SCHEMA party;

--Create schema administrative--
DROP SCHEMA IF EXISTS administrative CASCADE;
        
CREATE SCHEMA administrative;

--Create schema cadastre--
DROP SCHEMA IF EXISTS cadastre CASCADE;
        
CREATE SCHEMA cadastre;

--Create schema application--
DROP SCHEMA IF EXISTS application CASCADE;
        
CREATE SCHEMA application;

--Create schema address--
DROP SCHEMA IF EXISTS address CASCADE;
        
CREATE SCHEMA address;

--Create schema system--
DROP SCHEMA IF EXISTS system CASCADE;
        
CREATE SCHEMA system;

--Create schema document--
DROP SCHEMA IF EXISTS document CASCADE;
        
CREATE SCHEMA document;

--Create schema transaction--
DROP SCHEMA IF EXISTS transaction CASCADE;
        
CREATE SCHEMA transaction;

--Adding handy common functions --

-- Enable/disable all the triggers in database --
CREATE OR REPLACE FUNCTION fn_triggerall(DoEnable boolean) RETURNS integer AS
$BODY$
DECLARE
rec RECORD;
BEGIN
  FOR rec IN select * from information_schema.tables where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema')
  LOOP
    IF DoEnable THEN
      EXECUTE 'ALTER TABLE "'  || rec.table_schema || '"."' ||  rec.table_name || '" ENABLE TRIGGER ALL';
    ELSE
      EXECUTE 'ALTER TABLE "'  || rec.table_schema || '"."' ||  rec.table_name || '" DISABLE TRIGGER ALL';
    END IF; 
  END LOOP;
 
  RETURN 1;
 
END;
$BODY$
LANGUAGE 'plpgsql';


-- to call to disable all triggers in all schemas in db
--select fn_triggerall(false);

-- to call to enable all triggers in all schemas in db
--select fn_triggerall(true);

CREATE OR REPLACE FUNCTION clean_db(schema_name character varying)
  RETURNS integer AS
$BODY$
DECLARE
rec RECORD;

BEGIN
  FOR rec IN select * from information_schema.tables 
	where table_type = 'BASE TABLE' and table_schema = schema_name and table_name not in ('geometry_columns', 'spatial_ref_sys')
  LOOP
      EXECUTE 'DROP TABLE IF EXISTS "'  || rec.table_schema || '"."' ||  rec.table_name || '" CASCADE;';
  END LOOP;
  FOR rec IN select '"' || routine_schema || '"."' || routine_name || '"'  as full_name 
        from information_schema.routines  where routine_schema='public' 
            and data_type = 'trigger' and routine_name not in ('postgis_cache_bbox', 'checkauthtrigger', 'f_for_trg_track_history', 'f_for_trg_track_changes')
  LOOP
      EXECUTE 'DROP FUNCTION IF EXISTS '  || rec.full_name || '() CASCADE;';    
  END LOOP;
  RETURN 1;
 
END;
$BODY$
  LANGUAGE plpgsql;

-- Special string compare function
CREATE OR REPLACE FUNCTION compare_strings(string1 text, string2 text)
  RETURNS boolean AS
$BODY$
  DECLARE
    rec record;
    result boolean;
  BEGIN
      result = false;
      for rec in select regexp_split_to_table(lower(string1),'[^a-z0-9]') as word loop
          if rec.word != '' then 
            if not string2 ~* rec.word then
                return false;
            end if;
            result = true;
          end if;
      end loop;
      return result;
  END;
$BODY$
  LANGUAGE plpgsql;

--Usage sample:
-- select geom_to_snap, target_geom, snapped, target_is_changed 
-- FROM snap_geometry_to_geometry(geomfromtext('POLYGON((0.1 0, 0.1 5.7, 4 3, 0.1 0))'), 
--    geomfromtext('POLYGON((0 0, 0 6, 6 6, 6 0, 0 0),(1 1, 3 5, 4 5, 1 1))'), 1, true)

create or replace function snap_geometry_to_geometry(
  inout geom_to_snap geometry, -- Geometry that has to be snapped. It can be point, linestring or polygon
  inout target_geom geometry, -- Geometry that will be the target to used for snapping
  snap_distance float, -- The snap distance in meters
  change_target_if_needed boolean, -- It gives if it is allowed to change target during snapping
  out snapped boolean, -- An output value showing if the geometry is snapped. If it is a linestring or polygon, even if one point of them is snapped it returns true.
  out target_is_changed boolean -- It shows if the target changed during the snapping process
  ) 
returns record as
$BODY$
DECLARE
  i integer;
  nr_elements integer;
  rec record;
  point_location float;
  rings geometry[];
  
BEGIN
  target_is_changed = false;
  snapped = false;
  if st_geometrytype(geom_to_snap) not in ('ST_Point', 'ST_LineString', 'ST_Polygon') then
    raise exception 'geom_to_snap not supported. Only point, linestring and polygon is supported.';
  end if;
  if st_geometrytype(geom_to_snap) = 'ST_Point' then
    -- If the geometry to snap is POINT
    if st_geometrytype(target_geom) = 'ST_Point' then
      if st_dwithin(geom_to_snap, target_geom, snap_distance) then
        geom_to_snap = target_geom;
        snapped = true;
      end if;
    elseif st_geometrytype(target_geom) = 'ST_LineString' then
      -- Check first if there is any point of linestring where the point can be snapped.
      select t.* into rec from ST_DumpPoints(target_geom) t where st_dwithin(geom_to_snap, t.geom, snap_distance);
      if rec is not null then
        geom_to_snap = rec.geom;
        snapped = true;
        return;
      end if;
      --Check second if the point is within distance from linestring and get an interpolation point in the line.
      if st_dwithin(geom_to_snap, target_geom, snap_distance) then
        point_location = ST_Line_Locate_Point(target_geom, geom_to_snap);
        geom_to_snap = ST_Line_Interpolate_Point(target_geom, point_location);
        if change_target_if_needed then
          target_geom = ST_LineMerge(ST_Union(ST_Line_Substring(target_geom, 0, point_location), ST_Line_Substring(target_geom, point_location, 1)));
          target_is_changed = true;
        end if;
        snapped = true;  
      end if;
    elseif st_geometrytype(target_geom) = 'ST_Polygon' then
      select  array_agg(ST_ExteriorRing(geom)) into rings from ST_DumpRings(target_geom);
      nr_elements = array_upper(rings,1);
      i = 1;
      while i <= nr_elements loop
        select t.* into rec from snap_geometry_to_geometry(geom_to_snap, rings[i], snap_distance, change_target_if_needed) t;
        if rec.snapped then
          geom_to_snap = rec.geom_to_snap;
          snapped = true;
          if change_target_if_needed then
            rings[i] = rec.target_geom;
            target_geom = ST_MakePolygon(rings[1], rings[2:nr_elements]);
            target_is_changed = rec.target_is_changed;
            return;
          end if;
        end if;
        i = i+1;
      end loop;
    end if;
  elseif st_geometrytype(geom_to_snap) = 'ST_LineString' then
    nr_elements = st_npoints(geom_to_snap);
    i = 1;
    while i <= nr_elements loop
      select t.* into rec
        from snap_geometry_to_geometry(st_pointn(geom_to_snap,i), target_geom, snap_distance, change_target_if_needed) t;
      if rec.snapped then
        if rec.target_is_changed then
          target_geom= rec.target_geom;
          target_is_changed = true;
        end if;
        geom_to_snap = st_setpoint(geom_to_snap, i-1, rec.geom_to_snap);
        snapped = true;
      end if;
      i = i+1;
    end loop;    
  elseif st_geometrytype(geom_to_snap) = 'ST_Polygon' then
    select  array_agg(ST_ExteriorRing(geom)) into rings from ST_DumpRings(geom_to_snap);
    nr_elements = array_upper(rings,1);
    i = 1;
    while i <= nr_elements loop
      select t.* into rec
        from snap_geometry_to_geometry(rings[i], target_geom, snap_distance, change_target_if_needed) t;
      if rec.snapped then
        rings[i] = rec.geom_to_snap;
        if rec.target_is_changed then
          target_geom = rec.target_geom;
          target_is_changed = true;
        end if;
        snapped = true;
      end if;
      i= i+1;
    end loop;
    if snapped then
      geom_to_snap = ST_MakePolygon(rings[1], rings[2:nr_elements]);
    end if;
  end if;
  return;
END;
$BODY$
  LANGUAGE plpgsql;

-- This function assigns a srid found in the settings to the geometry passed as parameter  
CREATE OR REPLACE FUNCTION get_geometry_with_srid(geom geometry)
  RETURNS geometry AS
$BODY$
BEGIN
  return st_setsrid(geom, coalesce((select vl::integer from system.setting where name='map-srid'),-1));
END;
$BODY$
  LANGUAGE plpgsql;

-- This function is used to translate the values that are supposed to be multilingual like 
-- the reference data values (display_value)
CREATE OR REPLACE FUNCTION get_translation(mixed_value varchar, language_code varchar) RETURNS varchar AS
$BODY$
DECLARE
  delimiter_word varchar;
  language_index integer;
  result varchar;
BEGIN
  if mixed_value is null then
    return mixed_value;
  end if;
  delimiter_word = '::::';
  language_index = (select item_order from system.language where code=language_code);
  result = split_part(mixed_value, delimiter_word, language_index);
  if result is null or result = '' then
    language_index = (select item_order from system.language where is_default limit 1);
    result = split_part(mixed_value, delimiter_word, language_index);
    if result is null or result = '' then
      result = mixed_value;
    end if;
  end if;
  return result;
END;
$BODY$
LANGUAGE 'plpgsql';

    
--Adding functions --


-- Function public.nepali_to_englishdate -----
CREATE OR REPLACE FUNCTION public.nepali_to_englishdate(
    nepalidatestring varchar)
RETURNS date AS
$BODY$
DECLARE
constDate Date:='2007-04-14';
nep_yr integer[] := '{}';
nep_mth integer[]:='{}';
dys integer[] := '{}';
retDate Date;
yr integer;
mm integer;
d integer;
cnt integer;
dt Date;
r integer;
r1 integer;
i integer;
dd integer:=0;
BEGIN
dt:=nepalidatestring;
SELECT into yr EXTRACT(YEAR FROM  dt);
SELECT into mm EXTRACT(MONTH FROM  dt);
SELECT into d EXTRACT(DAY FROM  dt);
select count('nep_year') into cnt from system.np_calendar;
i:=0;
for r in select "nep_year" from system.np_calendar order by "nep_year","nep_month" ASC loop
nep_yr[i]:=r;
i=i+1;
end loop;

i:=0;
for r in select "nep_month" from system.np_calendar order by "nep_year","nep_month" ASC loop
nep_mth[i]:=r;
i=i+1;
end loop;

i:=0;
for r in select "dayss" from system.np_calendar order by "nep_year","nep_month" ASC loop
dys[i]:=r;
i=i+1;
end loop;
i:=0;
WHILE i<= cnt LOOP
    if nep_yr[i]=yr and nep_mth[i]=mm then
	Exit;
	else
	dd=dd+dys[i];
    end if;
    i=i+1;
end LOOP;
dd=dd+d-1;
retDate:=constDate+dd;
--test:=yr||'-'||mm||'-'||d;
--test:=to_date(test, 'yyyy-mm-dd');
return retDate;

END$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION nepali_to_englishdate(character varying)
  OWNER TO postgres;
COMMENT ON FUNCTION nepali_to_englishdate(character varying) IS 'This function converts the given western date in the format "yyyy-MM-dd" to Nepali date';

-- Function public.english_to_nepalidatestring -----
CREATE OR REPLACE FUNCTION public.english_to_nepalidatestring(
    englishdate date)
RETURNS character varying AS
$BODY$
DECLARE
constDate Date:='2007-04-14';
nep_yr integer[] := '{}';
nep_mth integer[]:='{}';
dys integer[] := '{}';
retDate varchar(50);
yr integer:=0;
mm integer:=0;
d integer:=0;
cnt integer;
r integer;
r1 integer;
i integer;
dd integer:=0;
dateDiff integer:=0;
mnth varchar(2);
days varchar(2);

BEGIN
if englishdate< constDate then
RAISE EXCEPTION 'Invalid english date';
end if;
dateDiff=englishdate-constDate;
select count('nep_year') into cnt from system.np_calendar;

i=0;
for r in select "nep_year" from system.np_calendar order by "nep_year","nep_month" ASC loop
nep_yr[i]:=r;
i=i+1;
end loop;

i:=0;
for r in select "nep_month" from system.np_calendar order by "nep_year","nep_month" ASC loop
nep_mth[i]:=r;
i=i+1;
end loop;

i:=0;
for r in select "dayss" from system.np_calendar order by "nep_year","nep_month" ASC loop
dys[i]:=r;
i=i+1;
end loop;

i:=0;
WHILE i<= cnt LOOP
  if d<=dateDiff then
	d=d+dys[i];
	yr=nep_yr[i];
	mm=nep_mth[i];
	else
	d=d-dys[i-1];
	exit;
   end if;
   i=i+1;
end LOOP;

IF mm < 9 THEN
  mnth='0' || mm;
ELSE
  mnth=mm;
END IF;

d = dateDiff-d+1;

IF d < 9 THEN
  days='0' || d;
ELSE
  days=d;
END IF;
 
retDate=yr||'-'||mnth||'-'||days;
return retDate ;
END$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION english_to_nepalidatestring(date) OWNER TO postgres;
COMMENT ON FUNCTION english_to_nepalidatestring(date) IS 'This function converts the given western date in the format "yyyy-MM-dd" to Nepali date';--Adding trigger function to track changes--

CREATE OR REPLACE FUNCTION f_for_trg_track_changes() RETURNS TRIGGER 
AS $$
BEGIN
    IF (TG_OP = 'UPDATE') THEN
        IF (NEW.rowversion != OLD.rowversion) THEN
            RAISE EXCEPTION 'row_has_different_change_time';
        END IF;
        IF (NEW.change_action != 'd') THEN
            NEW.change_action := 'u';
        END IF;
        IF OLD.rowversion > 200000000 THEN
            NEW.rowversion = 1;
        ELSE
            NEW.rowversion = OLD.rowversion + 1;
        END IF;
    ELSIF (TG_OP = 'INSERT') THEN
        NEW.change_action := 'i';
        NEW.rowversion = 1;
    END IF;
    NEW.change_time := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
    --Adding trigger function to track changes--

CREATE OR REPLACE FUNCTION f_for_trg_track_history() RETURNS TRIGGER 
AS $$
DECLARE
    table_name varchar;
    table_name_historic varchar;
BEGIN
    table_name = TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
    table_name_historic = table_name || '_historic';
	IF (TG_OP = 'DELETE') THEN
		OLD.change_action := 'd';
    END IF;
    EXECUTE 'INSERT INTO ' || table_name_historic || ' SELECT $1.*;' USING OLD;
    IF (TG_OP = 'DELETE') THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
    
    
select clean_db('public');
    
    
--Table source.source ----
DROP TABLE IF EXISTS source.source CASCADE;
CREATE TABLE source.source(
    id varchar(40) NOT NULL,
    maintype varchar(20),
    la_nr varchar(20) NOT NULL,
    reference_nr varchar(20),
    archive_id varchar(40),
    acceptance date,
    recordation integer,
    submission date DEFAULT (now()),
    expiration_date date,
    ext_archive_id varchar(40),
    availability_status_code varchar(20) NOT NULL DEFAULT ('available'),
    type_code varchar(20) NOT NULL,
    content varchar(4000),
    status_code varchar(20),
    transaction_id varchar(40),
    owner varchar(255),
    description varchar(255),
    office_code varchar(20),
    packet_no varchar(50),
    tameli_no varchar(50),
    likhat_reg_no varchar(50),
    page_no varchar(50),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT source_pkey PRIMARY KEY (id)
);


CREATE INDEX source_index_on_rowidentifier ON source.source (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON source.source CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON source.source FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table source.source_historic used for the history of data of table source.source ---
DROP TABLE IF EXISTS source.source_historic CASCADE;
CREATE TABLE source.source_historic
(
    id varchar(40),
    maintype varchar(20),
    la_nr varchar(20),
    reference_nr varchar(20),
    archive_id varchar(40),
    acceptance date,
    recordation integer,
    submission date,
    expiration_date date,
    ext_archive_id varchar(40),
    availability_status_code varchar(20),
    type_code varchar(20),
    content varchar(4000),
    status_code varchar(20),
    transaction_id varchar(40),
    owner varchar(255),
    description varchar(255),
    office_code varchar(20),
    packet_no varchar(50),
    tameli_no varchar(50),
    likhat_reg_no varchar(50),
    page_no varchar(50),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX source_historic_index_on_rowidentifier ON source.source_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON source.source CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON source.source FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table source.availability_status_type ----
DROP TABLE IF EXISTS source.availability_status_type CASCADE;
CREATE TABLE source.availability_status_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL DEFAULT ('c'),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT availability_status_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT availability_status_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table source.availability_status_type -- 
insert into source.availability_status_type(code, display_value, status) values('archiveConverted', 'Converted::::Convertito', 'c');
insert into source.availability_status_type(code, display_value, status) values('archiveDestroyed', 'Destroyed::::Distrutto', 'x');
insert into source.availability_status_type(code, display_value, status) values('incomplete', 'Incomplete::::Incompleto', 'c');
insert into source.availability_status_type(code, display_value, status) values('archiveUnknown', 'Unknown::::Sconosciuto', 'c');
insert into source.availability_status_type(code, display_value, status, description) values('available', 'Available', 'c', 'Extension to LADM');



--Table source.administrative_source_type ----
DROP TABLE IF EXISTS source.administrative_source_type CASCADE;
CREATE TABLE source.administrative_source_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL,
    has_status bool NOT NULL DEFAULT (false),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT administrative_source_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT administrative_source_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table source.administrative_source_type -- 
insert into source.administrative_source_type(code, display_value, status, has_status) values('2201', 'Deed::::लिखत', 'c', false);
insert into source.administrative_source_type(code, display_value, status, has_status) values('2202', 'Application::::मिसील', 'c', false);
insert into source.administrative_source_type(code, display_value, status, has_status) values('2203', 'Court Order::::अदालती आदेश', 'c', false);
insert into source.administrative_source_type(code, display_value, status, has_status) values('2204', 'Land Napi::::जग्गा नाप जाँच ऐन', 'c', false);
insert into source.administrative_source_type(code, display_value, status, has_status) values('2205', 'Application::::निवेदन अनुसार', 'c', false);
insert into source.administrative_source_type(code, display_value, status, has_status) values('2206', 'Other::::अन्य', 'c', false);
insert into source.administrative_source_type(code, display_value, status, has_status) values('2207', 'Not Defined::::उल्लेख नभएको', 'x', false);
insert into source.administrative_source_type(code, display_value, status, has_status) values('2208', 'Letter::::चिठ्ठी', 'c', false);



--Table source.spatial_source ----
DROP TABLE IF EXISTS source.spatial_source CASCADE;
CREATE TABLE source.spatial_source(
    id varchar(40) NOT NULL,
    procedure varchar(255),
    type_code varchar(20) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT spatial_source_pkey PRIMARY KEY (id)
);


CREATE INDEX spatial_source_index_on_rowidentifier ON source.spatial_source (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON source.spatial_source CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON source.spatial_source FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table source.spatial_source_historic used for the history of data of table source.spatial_source ---
DROP TABLE IF EXISTS source.spatial_source_historic CASCADE;
CREATE TABLE source.spatial_source_historic
(
    id varchar(40),
    procedure varchar(255),
    type_code varchar(20),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX spatial_source_historic_index_on_rowidentifier ON source.spatial_source_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON source.spatial_source CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON source.spatial_source FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table source.spatial_source_type ----
DROP TABLE IF EXISTS source.spatial_source_type CASCADE;
CREATE TABLE source.spatial_source_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL DEFAULT ('t'),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT spatial_source_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT spatial_source_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table source.spatial_source_type -- 
insert into source.spatial_source_type(code, display_value, status) values('fieldSketch', 'Field Sketch::::Schizzo Campo', 'c');
insert into source.spatial_source_type(code, display_value, status) values('gnssSurvey', 'GNSS (GPS) Survey::::Rilevamento GNSS (GPS)', 'c');
insert into source.spatial_source_type(code, display_value, status) values('orthoPhoto', 'Orthophoto::::Foto Ortopanoramica', 'c');
insert into source.spatial_source_type(code, display_value, status) values('relativeMeasurement', 'Relative Measurements::::Misure relativa', 'c');
insert into source.spatial_source_type(code, display_value, status) values('topoMap', 'Topographical Map::::Mappa Topografica', 'c');
insert into source.spatial_source_type(code, display_value, status) values('video', 'Video::::Video', 'c');
insert into source.spatial_source_type(code, display_value, status, description) values('cadastralSurvey', 'Cadastral Survey::::Perizia Catastale', 'c', 'Extension to LADM');



--Table source.spatial_source_measurement ----
DROP TABLE IF EXISTS source.spatial_source_measurement CASCADE;
CREATE TABLE source.spatial_source_measurement(
    spatial_source_id varchar(40) NOT NULL,
    id varchar(40) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT spatial_source_measurement_pkey PRIMARY KEY (spatial_source_id,id)
);


CREATE INDEX spatial_source_measurement_index_on_rowidentifier ON source.spatial_source_measurement (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON source.spatial_source_measurement CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON source.spatial_source_measurement FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table source.spatial_source_measurement_historic used for the history of data of table source.spatial_source_measurement ---
DROP TABLE IF EXISTS source.spatial_source_measurement_historic CASCADE;
CREATE TABLE source.spatial_source_measurement_historic
(
    spatial_source_id varchar(40),
    id varchar(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX spatial_source_measurement_historic_index_on_rowidentifier ON source.spatial_source_measurement_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON source.spatial_source_measurement CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON source.spatial_source_measurement FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table party.party ----
DROP TABLE IF EXISTS party.party CASCADE;
CREATE TABLE party.party(
    id varchar(40) NOT NULL,
    is_child bool DEFAULT ('f'),
    parent_id varchar(40),
    ext_id varchar(255),
    type_code varchar(20) NOT NULL,
    name varchar(255),
    last_name varchar(50),
    father_type_code varchar(20),
    fathers_name varchar(255),
    grandfather_type_code varchar(20),
    grandfather_name varchar(255),
    alias varchar(50),
    gender_code varchar(20),
    address_id varchar(40),
    id_type_code varchar(20),
    id_number varchar(20),
    id_issue_date integer,
    id_office_type_code varchar(20),
    id_office_district_code varchar(20),
    email varchar(50),
    mobile varchar(15),
    phone varchar(15),
    fax varchar(15),
    preferred_communication_code varchar(20),
    date_of_birth integer,
    remarks varchar(200),
    office_code varchar(20),
    photo_id varchar(40),
    left_finger_id varchar(40),
    right_finger_id varchar(40),
    signature_id varchar(40),
    handicapped bool DEFAULT (false),
    deprived bool DEFAULT (false),
    martyrs bool DEFAULT (false),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT party_id_is_present CHECK ((id_type_code is null and id_number is null) or ((id_type_code is not null and id_number is not null))),
    CONSTRAINT party_pkey PRIMARY KEY (id)
);


CREATE INDEX party_index_on_rowidentifier ON party.party (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON party.party CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON party.party FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table party.party_historic used for the history of data of table party.party ---
DROP TABLE IF EXISTS party.party_historic CASCADE;
CREATE TABLE party.party_historic
(
    id varchar(40),
    is_child bool,
    parent_id varchar(40),
    ext_id varchar(255),
    type_code varchar(20),
    name varchar(255),
    last_name varchar(50),
    father_type_code varchar(20),
    fathers_name varchar(255),
    grandfather_type_code varchar(20),
    grandfather_name varchar(255),
    alias varchar(50),
    gender_code varchar(20),
    address_id varchar(40),
    id_type_code varchar(20),
    id_number varchar(20),
    id_issue_date integer,
    id_office_type_code varchar(20),
    id_office_district_code varchar(20),
    email varchar(50),
    mobile varchar(15),
    phone varchar(15),
    fax varchar(15),
    preferred_communication_code varchar(20),
    date_of_birth integer,
    remarks varchar(200),
    office_code varchar(20),
    photo_id varchar(40),
    left_finger_id varchar(40),
    right_finger_id varchar(40),
    signature_id varchar(40),
    handicapped bool,
    deprived bool,
    martyrs bool,
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX party_historic_index_on_rowidentifier ON party.party_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON party.party CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON party.party FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table party.party_type ----
DROP TABLE IF EXISTS party.party_type CASCADE;
CREATE TABLE party.party_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL DEFAULT ('t'),
    description varchar(555),
    individual bool NOT NULL DEFAULT ('t'),

    -- Internal constraints
    
    CONSTRAINT party_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT party_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table party.party_type -- 
insert into party.party_type(code, display_value, status, individual) values('1800', 'Not Specified::::उल्लेख नभएको', 'c', true);
insert into party.party_type(code, display_value, status, individual) values('1801', 'Indiviual::::व्यक्रिगत', 'c', true);
insert into party.party_type(code, display_value, status, individual) values('1802', 'Guthi::::सामाजिक संस्था', 'c', false);
insert into party.party_type(code, display_value, status, individual) values('1803', 'Government Office::::सरकारी कायार्लय', 'c', false);
insert into party.party_type(code, display_value, status, individual) values('1804', 'वित्तिय संस्था', 'c', true);
insert into party.party_type(code, display_value, status, individual) values('1805', 'Guthi::::गुठी', 'c', false);
insert into party.party_type(code, display_value, status, individual) values('1806', 'प्राज्ञिक संस्था', 'c', false);
insert into party.party_type(code, display_value, status, individual) values('1807', 'खेलकुद संस्था', 'c', false);
insert into party.party_type(code, display_value, status, individual) values('1808', 'सावर्जनिक संस्था', 'c', false);
insert into party.party_type(code, display_value, status, individual) values('1809', 'प्राईभेट संस्था', 'c', false);
insert into party.party_type(code, display_value, status, individual) values('1810', 'Minor::::नाबालाक', 'c', true);
insert into party.party_type(code, display_value, status, individual) values('1899', 'Guardian::::संरक्षक', 'c', true);



--Table party.group_party ----
DROP TABLE IF EXISTS party.group_party CASCADE;
CREATE TABLE party.group_party(
    id varchar(40) NOT NULL,
    type_code varchar(20) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT group_party_pkey PRIMARY KEY (id)
);


CREATE INDEX group_party_index_on_rowidentifier ON party.group_party (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON party.group_party CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON party.group_party FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table party.group_party_historic used for the history of data of table party.group_party ---
DROP TABLE IF EXISTS party.group_party_historic CASCADE;
CREATE TABLE party.group_party_historic
(
    id varchar(40),
    type_code varchar(20),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX group_party_historic_index_on_rowidentifier ON party.group_party_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON party.group_party CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON party.group_party FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table party.group_party_type ----
DROP TABLE IF EXISTS party.group_party_type CASCADE;
CREATE TABLE party.group_party_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL DEFAULT ('t'),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT group_party_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT group_party_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table party.group_party_type -- 
insert into party.group_party_type(code, display_value, status) values('tribe', 'Tribe::::Tribu', 'x');
insert into party.group_party_type(code, display_value, status) values('association', 'Association::::Associazione', 'c');
insert into party.group_party_type(code, display_value, status) values('family', 'Family::::Famiglia', 'c');
insert into party.group_party_type(code, display_value, status) values('baunitGroup', 'Basic Administrative Unit Group::::Unita Gruppo Amministrativo di Base', 'x');



--Table party.party_member ----
DROP TABLE IF EXISTS party.party_member CASCADE;
CREATE TABLE party.party_member(
    party_id varchar(40) NOT NULL,
    group_id varchar(40) NOT NULL,
    share double precision,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT party_member_pkey PRIMARY KEY (party_id,group_id)
);


CREATE INDEX party_member_index_on_rowidentifier ON party.party_member (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON party.party_member CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON party.party_member FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table party.party_member_historic used for the history of data of table party.party_member ---
DROP TABLE IF EXISTS party.party_member_historic CASCADE;
CREATE TABLE party.party_member_historic
(
    party_id varchar(40),
    group_id varchar(40),
    share double precision,
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX party_member_historic_index_on_rowidentifier ON party.party_member_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON party.party_member CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON party.party_member FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table administrative.ba_unit ----
DROP TABLE IF EXISTS administrative.ba_unit CASCADE;
CREATE TABLE administrative.ba_unit(
    id varchar(40) NOT NULL,
    type_code varchar(20),
    name varchar(255),
    name_firstpart varchar(20) NOT NULL,
    name_lastpart varchar(50) NOT NULL,
    cadastre_object_id varchar(40) NOT NULL,
    status_code varchar(20) NOT NULL DEFAULT ('pending'),
    transaction_id varchar(40),
    fy_code varchar(20) NOT NULL,
    office_code varchar(20) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT ba_unit_unique_cadastre_object UNIQUE (cadastre_object_id),
    CONSTRAINT ba_unit_pkey PRIMARY KEY (id)
);


CREATE INDEX ba_unit_index_on_rowidentifier ON administrative.ba_unit (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON administrative.ba_unit CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON administrative.ba_unit FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table administrative.ba_unit_historic used for the history of data of table administrative.ba_unit ---
DROP TABLE IF EXISTS administrative.ba_unit_historic CASCADE;
CREATE TABLE administrative.ba_unit_historic
(
    id varchar(40),
    type_code varchar(20),
    name varchar(255),
    name_firstpart varchar(20),
    name_lastpart varchar(50),
    cadastre_object_id varchar(40),
    status_code varchar(20),
    transaction_id varchar(40),
    fy_code varchar(20),
    office_code varchar(20),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX ba_unit_historic_index_on_rowidentifier ON administrative.ba_unit_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON administrative.ba_unit CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON administrative.ba_unit FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table administrative.ba_unit_type ----
DROP TABLE IF EXISTS administrative.ba_unit_type CASCADE;
CREATE TABLE administrative.ba_unit_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('t'),

    -- Internal constraints
    
    CONSTRAINT ba_unit_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT ba_unit_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table administrative.ba_unit_type -- 
insert into administrative.ba_unit_type(code, display_value, status) values('basicPropertyUnit', 'Basic Property Unit::::Unita base Proprieta', 'c');
insert into administrative.ba_unit_type(code, display_value, status) values('leasedUnit', 'Leased Unit::::Unita Affitto', 'x');
insert into administrative.ba_unit_type(code, display_value, status) values('propertyRightUnit', 'Property Right Unit::::Unita Diritto Proprieta', 'x');
insert into administrative.ba_unit_type(code, display_value, description, status) values('administrativeUnit', 'Administrative Unit::::Unita Amministrativa', 'Extension to LADM', 'c');
insert into administrative.ba_unit_type(code, display_value, description, status) values('basicParcel', 'Basic Parcel::::Particella Base', 'Extension to LADM', 'c');



--Table administrative.rrr ----
DROP TABLE IF EXISTS administrative.rrr CASCADE;
CREATE TABLE administrative.rrr(
    id varchar(40) NOT NULL,
    ba_unit_id varchar(40) NOT NULL,
    fy_code varchar(20) NOT NULL,
    nr varchar(20) NOT NULL,
    sn varchar(20),
    type_code varchar(20) NOT NULL,
    status_code varchar(20) NOT NULL DEFAULT ('pending'),
    is_primary bool NOT NULL DEFAULT (false),
    transaction_id varchar(40) NOT NULL,
    registration_number varchar(20),
    registration_date integer,
    owner_type_code varchar(20),
    ownership_type_code varchar(20),
    expiration_date integer,
    mortgage_amount numeric(29, 2),
    mortgage_interest_rate numeric(5, 2),
    mortgage_ranking integer,
    mortgage_type_code varchar(20),
    loc_id varchar(40),
    is_terminating bool NOT NULL DEFAULT (false),
    restriction_reason_code varchar(20),
    restriction_office_name varchar(255),
    restriction_release_office_name varchar(255),
    restriction_office_address varchar(255),
    restriction_release_reason_code varchar(20),
    tenancy_type_code varchar(20),
    bundle_number varchar(15),
    bundle_page_no varchar(10),
    office_code varchar(20) NOT NULL,
    valuation_amount numeric(29, 2) NOT NULL DEFAULT (0),
    tax_amount numeric(29, 2) NOT NULL DEFAULT (0),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT rrr_pkey PRIMARY KEY (id)
);


CREATE INDEX rrr_index_on_rowidentifier ON administrative.rrr (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON administrative.rrr CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON administrative.rrr FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table administrative.rrr_historic used for the history of data of table administrative.rrr ---
DROP TABLE IF EXISTS administrative.rrr_historic CASCADE;
CREATE TABLE administrative.rrr_historic
(
    id varchar(40),
    ba_unit_id varchar(40),
    fy_code varchar(20),
    nr varchar(20),
    sn varchar(20),
    type_code varchar(20),
    status_code varchar(20),
    is_primary bool,
    transaction_id varchar(40),
    registration_number varchar(20),
    registration_date integer,
    owner_type_code varchar(20),
    ownership_type_code varchar(20),
    expiration_date integer,
    mortgage_amount numeric(29, 2),
    mortgage_interest_rate numeric(5, 2),
    mortgage_ranking integer,
    mortgage_type_code varchar(20),
    loc_id varchar(40),
    is_terminating bool,
    restriction_reason_code varchar(20),
    restriction_office_name varchar(255),
    restriction_release_office_name varchar(255),
    restriction_office_address varchar(255),
    restriction_release_reason_code varchar(20),
    tenancy_type_code varchar(20),
    bundle_number varchar(15),
    bundle_page_no varchar(10),
    office_code varchar(20),
    valuation_amount numeric(29, 2),
    tax_amount numeric(29, 2),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX rrr_historic_index_on_rowidentifier ON administrative.rrr_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON administrative.rrr CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON administrative.rrr FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table administrative.rrr_group_type ----
DROP TABLE IF EXISTS administrative.rrr_group_type CASCADE;
CREATE TABLE administrative.rrr_group_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT rrr_group_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT rrr_group_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table administrative.rrr_group_type -- 
insert into administrative.rrr_group_type(code, display_value, status) values('rights', 'Rights::::Diritti', 'c');
insert into administrative.rrr_group_type(code, display_value, status) values('restrictions', 'Restrictions::::Restrizioni', 'c');
insert into administrative.rrr_group_type(code, display_value, status) values('responsibilities', 'Responsibilities::::Responsabilita', 'x');
insert into administrative.rrr_group_type(code, display_value, status) values('ownership', 'Ownership::::Ownership', 'c');



--Table administrative.rrr_type ----
DROP TABLE IF EXISTS administrative.rrr_type CASCADE;
CREATE TABLE administrative.rrr_type(
    code varchar(20) NOT NULL,
    rrr_group_type_code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    is_primary bool NOT NULL DEFAULT (false),
    share_check bool NOT NULL,
    party_required bool NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('t'),

    -- Internal constraints
    
    CONSTRAINT rrr_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT rrr_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table administrative.rrr_type -- 
insert into administrative.rrr_type(code, rrr_group_type_code, display_value, is_primary, share_check, party_required, status) values('ownership', 'ownership', 'Ownership::::Proprieta', true, true, true, 'c');
insert into administrative.rrr_type(code, rrr_group_type_code, display_value, is_primary, share_check, party_required, status) values('tenancy', 'rights', 'Tenancy::::Locazione', true, true, true, 'c');
insert into administrative.rrr_type(code, rrr_group_type_code, display_value, is_primary, share_check, party_required, description, status) values('simpleRestriction', 'restrictions', 'Restriction', false, false, false, '', 'c');



--Table administrative.mortgage_type ----
DROP TABLE IF EXISTS administrative.mortgage_type CASCADE;
CREATE TABLE administrative.mortgage_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT mortgage_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT mortgage_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table administrative.mortgage_type -- 
insert into administrative.mortgage_type(code, display_value, status) values('levelPayment', 'Level Payment::::Livello Pagamento', 'c');
insert into administrative.mortgage_type(code, display_value, status) values('linear', 'Linear::::Lineare', 'c');
insert into administrative.mortgage_type(code, display_value, status) values('microCredit', 'Micro Credit::::Micro Credito', 'c');



--Table administrative.source_describes_rrr ----
DROP TABLE IF EXISTS administrative.source_describes_rrr CASCADE;
CREATE TABLE administrative.source_describes_rrr(
    rrr_id varchar(40) NOT NULL,
    source_id varchar(40) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT source_describes_rrr_pkey PRIMARY KEY (rrr_id,source_id)
);


CREATE INDEX source_describes_rrr_index_on_rowidentifier ON administrative.source_describes_rrr (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON administrative.source_describes_rrr CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON administrative.source_describes_rrr FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table administrative.source_describes_rrr_historic used for the history of data of table administrative.source_describes_rrr ---
DROP TABLE IF EXISTS administrative.source_describes_rrr_historic CASCADE;
CREATE TABLE administrative.source_describes_rrr_historic
(
    rrr_id varchar(40),
    source_id varchar(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX source_describes_rrr_historic_index_on_rowidentifier ON administrative.source_describes_rrr_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON administrative.source_describes_rrr CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON administrative.source_describes_rrr FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table administrative.source_describes_ba_unit ----
DROP TABLE IF EXISTS administrative.source_describes_ba_unit CASCADE;
CREATE TABLE administrative.source_describes_ba_unit(
    ba_unit_id varchar(40) NOT NULL,
    source_id varchar(40) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT source_describes_ba_unit_pkey PRIMARY KEY (ba_unit_id,source_id)
);


CREATE INDEX source_describes_ba_unit_index_on_rowidentifier ON administrative.source_describes_ba_unit (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON administrative.source_describes_ba_unit CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON administrative.source_describes_ba_unit FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table administrative.source_describes_ba_unit_historic used for the history of data of table administrative.source_describes_ba_unit ---
DROP TABLE IF EXISTS administrative.source_describes_ba_unit_historic CASCADE;
CREATE TABLE administrative.source_describes_ba_unit_historic
(
    ba_unit_id varchar(40),
    source_id varchar(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX source_describes_ba_unit_historic_index_on_rowidentifier ON administrative.source_describes_ba_unit_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON administrative.source_describes_ba_unit CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON administrative.source_describes_ba_unit FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table administrative.required_relationship_baunit ----
DROP TABLE IF EXISTS administrative.required_relationship_baunit CASCADE;
CREATE TABLE administrative.required_relationship_baunit(
    from_ba_unit_id varchar(40) NOT NULL,
    to_ba_unit_id varchar(40) NOT NULL,
    relation_code varchar(20) NOT NULL,
    transaction_id varchar(40) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT required_relationship_baunit_pkey PRIMARY KEY (from_ba_unit_id,to_ba_unit_id)
);


CREATE INDEX required_relationship_baunit_index_on_rowidentifier ON administrative.required_relationship_baunit (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON administrative.required_relationship_baunit CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON administrative.required_relationship_baunit FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table administrative.required_relationship_baunit_historic used for the history of data of table administrative.required_relationship_baunit ---
DROP TABLE IF EXISTS administrative.required_relationship_baunit_historic CASCADE;
CREATE TABLE administrative.required_relationship_baunit_historic
(
    from_ba_unit_id varchar(40),
    to_ba_unit_id varchar(40),
    relation_code varchar(20),
    transaction_id varchar(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX required_relationship_baunit_historic_index_on_rowidentifier ON administrative.required_relationship_baunit_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON administrative.required_relationship_baunit CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON administrative.required_relationship_baunit FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table cadastre.spatial_unit ----
DROP TABLE IF EXISTS cadastre.spatial_unit CASCADE;
CREATE TABLE cadastre.spatial_unit(
    id varchar(40) NOT NULL,
    dimension_code varchar(20) NOT NULL DEFAULT ('2D'),
    label varchar(255),
    surface_relation_code varchar(20) NOT NULL DEFAULT ('onSurface'),
    level_id varchar(40),
    reference_point GEOMETRY,
    CONSTRAINT enforce_dims_reference_point CHECK (st_ndims(reference_point) = 2),
    
            CONSTRAINT enforce_srid_reference_point CHECK (st_srid(reference_point) = 97261),
    CONSTRAINT enforce_geotype_reference_point CHECK (geometrytype(reference_point) = 'POINT'::text OR reference_point IS NULL),
    geom GEOMETRY,
    CONSTRAINT enforce_dims_geom CHECK (st_ndims(geom) = 2),
    
            CONSTRAINT enforce_srid_geom CHECK (st_srid(geom) = 97261),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT spatial_unit_pkey PRIMARY KEY (id)
);


CREATE INDEX spatial_unit_index_on_rowidentifier ON cadastre.spatial_unit (rowidentifier);
CREATE INDEX spatial_unit_index_on_reference_point ON cadastre.spatial_unit USING gist (reference_point);
CREATE INDEX spatial_unit_index_on_geom ON cadastre.spatial_unit USING gist (geom);

    
DROP TRIGGER IF EXISTS __track_changes ON cadastre.spatial_unit CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON cadastre.spatial_unit FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table cadastre.spatial_unit_historic used for the history of data of table cadastre.spatial_unit ---
DROP TABLE IF EXISTS cadastre.spatial_unit_historic CASCADE;
CREATE TABLE cadastre.spatial_unit_historic
(
    id varchar(40),
    dimension_code varchar(20),
    label varchar(255),
    surface_relation_code varchar(20),
    level_id varchar(40),
    reference_point GEOMETRY,
    CONSTRAINT enforce_dims_reference_point CHECK (st_ndims(reference_point) = 2),
    
            CONSTRAINT enforce_srid_reference_point CHECK (st_srid(reference_point) = 97261),
    CONSTRAINT enforce_geotype_reference_point CHECK (geometrytype(reference_point) = 'POINT'::text OR reference_point IS NULL),
    geom GEOMETRY,
    CONSTRAINT enforce_dims_geom CHECK (st_ndims(geom) = 2),
    
            CONSTRAINT enforce_srid_geom CHECK (st_srid(geom) = 97261),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX spatial_unit_historic_index_on_rowidentifier ON cadastre.spatial_unit_historic (rowidentifier);
CREATE INDEX spatial_unit_historic_index_on_reference_point ON cadastre.spatial_unit_historic USING gist (reference_point);
CREATE INDEX spatial_unit_historic_index_on_geom ON cadastre.spatial_unit_historic USING gist (geom);


DROP TRIGGER IF EXISTS __track_history ON cadastre.spatial_unit CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON cadastre.spatial_unit FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table cadastre.spatial_value_area ----
DROP TABLE IF EXISTS cadastre.spatial_value_area CASCADE;
CREATE TABLE cadastre.spatial_value_area(
    spatial_unit_id varchar(40) NOT NULL,
    type_code varchar(20) NOT NULL,
    size numeric(29, 2) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT spatial_value_area_pkey PRIMARY KEY (spatial_unit_id,type_code)
);


CREATE INDEX spatial_value_area_index_on_rowidentifier ON cadastre.spatial_value_area (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON cadastre.spatial_value_area CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON cadastre.spatial_value_area FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table cadastre.spatial_value_area_historic used for the history of data of table cadastre.spatial_value_area ---
DROP TABLE IF EXISTS cadastre.spatial_value_area_historic CASCADE;
CREATE TABLE cadastre.spatial_value_area_historic
(
    spatial_unit_id varchar(40),
    type_code varchar(20),
    size numeric(29, 2),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX spatial_value_area_historic_index_on_rowidentifier ON cadastre.spatial_value_area_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON cadastre.spatial_value_area CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON cadastre.spatial_value_area FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table cadastre.area_type ----
DROP TABLE IF EXISTS cadastre.area_type CASCADE;
CREATE TABLE cadastre.area_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('c'),

    -- Internal constraints
    
    CONSTRAINT area_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT area_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.area_type -- 
insert into cadastre.area_type(code, display_value, status) values('calculatedArea', 'Calculated Area::::Area calcolata', 'c');
insert into cadastre.area_type(code, display_value, status) values('nonOfficialArea', 'Non-official Area::::Area Non ufficiale', 'c');
insert into cadastre.area_type(code, display_value, status) values('officialArea', 'Official Area::::Area Ufficiale', 'c');
insert into cadastre.area_type(code, display_value, status) values('surveyedArea', 'Surveyed Area::::Area Sorvegliata', 'c');



--Table cadastre.surface_relation_type ----
DROP TABLE IF EXISTS cadastre.surface_relation_type CASCADE;
CREATE TABLE cadastre.surface_relation_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('t'),

    -- Internal constraints
    
    CONSTRAINT surface_relation_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT surface_relation_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.surface_relation_type -- 
insert into cadastre.surface_relation_type(code, display_value, status) values('above', 'Above::::Sopra', 'x');
insert into cadastre.surface_relation_type(code, display_value, status) values('below', 'Below::::Sotto', 'x');
insert into cadastre.surface_relation_type(code, display_value, status) values('mixed', 'Mixed::::Misto', 'x');
insert into cadastre.surface_relation_type(code, display_value, status) values('onSurface', 'On Surface::::Sulla Superficie', 'c');



--Table cadastre.level ----
DROP TABLE IF EXISTS cadastre.level CASCADE;
CREATE TABLE cadastre.level(
    id varchar(40) NOT NULL,
    name varchar(50),
    register_type_code varchar(20) NOT NULL,
    structure_code varchar(20),
    type_code varchar(20),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT level_pkey PRIMARY KEY (id)
);


CREATE INDEX level_index_on_rowidentifier ON cadastre.level (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON cadastre.level CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON cadastre.level FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table cadastre.level_historic used for the history of data of table cadastre.level ---
DROP TABLE IF EXISTS cadastre.level_historic CASCADE;
CREATE TABLE cadastre.level_historic
(
    id varchar(40),
    name varchar(50),
    register_type_code varchar(20),
    structure_code varchar(20),
    type_code varchar(20),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX level_historic_index_on_rowidentifier ON cadastre.level_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON cadastre.level CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON cadastre.level FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table cadastre.register_type ----
DROP TABLE IF EXISTS cadastre.register_type CASCADE;
CREATE TABLE cadastre.register_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT register_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT register_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.register_type -- 
insert into cadastre.register_type(code, display_value, status) values('all', 'All::::Tutti', 'c');
insert into cadastre.register_type(code, display_value, status) values('forest', 'Forest::::Forestale', 'c');
insert into cadastre.register_type(code, display_value, status) values('mining', 'Mining::::Minerario', 'c');
insert into cadastre.register_type(code, display_value, status) values('publicSpace', 'Public Space::::Spazio Pubblico', 'c');
insert into cadastre.register_type(code, display_value, status) values('rural', 'Rural::::Rurale', 'c');
insert into cadastre.register_type(code, display_value, status) values('urban', 'Urban::::Urbano', 'c');



--Table cadastre.structure_type ----
DROP TABLE IF EXISTS cadastre.structure_type CASCADE;
CREATE TABLE cadastre.structure_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('t'),

    -- Internal constraints
    
    CONSTRAINT structure_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT structure_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.structure_type -- 
insert into cadastre.structure_type(code, display_value, status) values('point', 'Point::::Punto', 'c');
insert into cadastre.structure_type(code, display_value, status) values('polygon', 'Polygon::::Poligono', 'c');
insert into cadastre.structure_type(code, display_value, status) values('sketch', 'Sketch::::Schizzo', 'c');
insert into cadastre.structure_type(code, display_value, status) values('text', 'Text::::Testo', 'c');
insert into cadastre.structure_type(code, display_value, status) values('topological', 'Topological::::Topologico', 'c');
insert into cadastre.structure_type(code, display_value) values('unStructuredLine', 'UnstructuredLine::::LineanonDefinita');



--Table cadastre.level_content_type ----
DROP TABLE IF EXISTS cadastre.level_content_type CASCADE;
CREATE TABLE cadastre.level_content_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('t'),

    -- Internal constraints
    
    CONSTRAINT level_content_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT level_content_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.level_content_type -- 
insert into cadastre.level_content_type(code, display_value, status) values('building', 'Building::::Costruzione', 'x');
insert into cadastre.level_content_type(code, display_value, status) values('customary', 'Customary::::Consueto', 'x');
insert into cadastre.level_content_type(code, display_value, status) values('informal', 'Informal::::Informale', 'x');
insert into cadastre.level_content_type(code, display_value, status) values('mixed', 'Mixed::::Misto', 'x');
insert into cadastre.level_content_type(code, display_value, status) values('network', 'Network::::Rete', 'x');
insert into cadastre.level_content_type(code, display_value, status) values('primaryRight', 'Primary Right::::Diritto Primario', 'c');
insert into cadastre.level_content_type(code, display_value, status) values('responsibility', 'Responsibility::::Responsabilita', 'x');
insert into cadastre.level_content_type(code, display_value, status) values('restriction', 'Restriction::::Restrizione', 'c');
insert into cadastre.level_content_type(code, display_value, description, status) values('geographicLocator', 'Geographic Locators::::Locatori Geografici', 'Extension to LADM', 'c');



--Table cadastre.spatial_unit_group ----
DROP TABLE IF EXISTS cadastre.spatial_unit_group CASCADE;
CREATE TABLE cadastre.spatial_unit_group(
    id varchar(40) NOT NULL,
    hierarchy_level integer NOT NULL,
    label varchar(50),
    name varchar(50),
    reference_point GEOMETRY,
    CONSTRAINT enforce_dims_reference_point CHECK (st_ndims(reference_point) = 2),
    
            CONSTRAINT enforce_srid_reference_point CHECK (st_srid(reference_point) = 97261),
    CONSTRAINT enforce_geotype_reference_point CHECK (geometrytype(reference_point) = 'POINT'::text OR reference_point IS NULL),
    geom GEOMETRY,
    CONSTRAINT enforce_dims_geom CHECK (st_ndims(geom) = 2),
    
            CONSTRAINT enforce_srid_geom CHECK (st_srid(geom) = 97261),
    CONSTRAINT enforce_geotype_geom CHECK (geometrytype(geom) = 'MULTIPOLYGON'::text OR geom IS NULL),
    found_in_spatial_unit_group_id varchar(40),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT spatial_unit_group_pkey PRIMARY KEY (id)
);


CREATE INDEX spatial_unit_group_index_on_rowidentifier ON cadastre.spatial_unit_group (rowidentifier);
CREATE INDEX spatial_unit_group_index_on_reference_point ON cadastre.spatial_unit_group USING gist (reference_point);
CREATE INDEX spatial_unit_group_index_on_geom ON cadastre.spatial_unit_group USING gist (geom);

    
DROP TRIGGER IF EXISTS __track_changes ON cadastre.spatial_unit_group CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON cadastre.spatial_unit_group FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table cadastre.spatial_unit_group_historic used for the history of data of table cadastre.spatial_unit_group ---
DROP TABLE IF EXISTS cadastre.spatial_unit_group_historic CASCADE;
CREATE TABLE cadastre.spatial_unit_group_historic
(
    id varchar(40),
    hierarchy_level integer,
    label varchar(50),
    name varchar(50),
    reference_point GEOMETRY,
    CONSTRAINT enforce_dims_reference_point CHECK (st_ndims(reference_point) = 2),
    
            CONSTRAINT enforce_srid_reference_point CHECK (st_srid(reference_point) = 97261),
    CONSTRAINT enforce_geotype_reference_point CHECK (geometrytype(reference_point) = 'POINT'::text OR reference_point IS NULL),
    geom GEOMETRY,
    CONSTRAINT enforce_dims_geom CHECK (st_ndims(geom) = 2),
    
            CONSTRAINT enforce_srid_geom CHECK (st_srid(geom) = 97261),
    CONSTRAINT enforce_geotype_geom CHECK (geometrytype(geom) = 'MULTIPOLYGON'::text OR geom IS NULL),
    found_in_spatial_unit_group_id varchar(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX spatial_unit_group_historic_index_on_rowidentifier ON cadastre.spatial_unit_group_historic (rowidentifier);
CREATE INDEX spatial_unit_group_historic_index_on_reference_point ON cadastre.spatial_unit_group_historic USING gist (reference_point);
CREATE INDEX spatial_unit_group_historic_index_on_geom ON cadastre.spatial_unit_group_historic USING gist (geom);


DROP TRIGGER IF EXISTS __track_history ON cadastre.spatial_unit_group CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON cadastre.spatial_unit_group FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table cadastre.spatial_unit_in_group ----
DROP TABLE IF EXISTS cadastre.spatial_unit_in_group CASCADE;
CREATE TABLE cadastre.spatial_unit_in_group(
    spatial_unit_group_id varchar(40) NOT NULL,
    spatial_unit_id varchar(40) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT spatial_unit_in_group_pkey PRIMARY KEY (spatial_unit_group_id,spatial_unit_id)
);


CREATE INDEX spatial_unit_in_group_index_on_rowidentifier ON cadastre.spatial_unit_in_group (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON cadastre.spatial_unit_in_group CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON cadastre.spatial_unit_in_group FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table cadastre.spatial_unit_in_group_historic used for the history of data of table cadastre.spatial_unit_in_group ---
DROP TABLE IF EXISTS cadastre.spatial_unit_in_group_historic CASCADE;
CREATE TABLE cadastre.spatial_unit_in_group_historic
(
    spatial_unit_group_id varchar(40),
    spatial_unit_id varchar(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX spatial_unit_in_group_historic_index_on_rowidentifier ON cadastre.spatial_unit_in_group_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON cadastre.spatial_unit_in_group CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON cadastre.spatial_unit_in_group FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table cadastre.legal_space_utility_network ----
DROP TABLE IF EXISTS cadastre.legal_space_utility_network CASCADE;
CREATE TABLE cadastre.legal_space_utility_network(
    id varchar(40) NOT NULL,
    ext_physical_network_id varchar(40),
    status_code varchar(20),
    type_code varchar(20) NOT NULL,
    geom GEOMETRY,
    CONSTRAINT enforce_dims_geom CHECK (st_ndims(geom) = 2),
    
            CONSTRAINT enforce_srid_geom CHECK (st_srid(geom) = 97261),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT legal_space_utility_network_pkey PRIMARY KEY (id)
);


CREATE INDEX legal_space_utility_network_index_on_rowidentifier ON cadastre.legal_space_utility_network (rowidentifier);
CREATE INDEX legal_space_utility_network_index_on_geom ON cadastre.legal_space_utility_network USING gist (geom);

    
DROP TRIGGER IF EXISTS __track_changes ON cadastre.legal_space_utility_network CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON cadastre.legal_space_utility_network FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table cadastre.legal_space_utility_network_historic used for the history of data of table cadastre.legal_space_utility_network ---
DROP TABLE IF EXISTS cadastre.legal_space_utility_network_historic CASCADE;
CREATE TABLE cadastre.legal_space_utility_network_historic
(
    id varchar(40),
    ext_physical_network_id varchar(40),
    status_code varchar(20),
    type_code varchar(20),
    geom GEOMETRY,
    CONSTRAINT enforce_dims_geom CHECK (st_ndims(geom) = 2),
    
            CONSTRAINT enforce_srid_geom CHECK (st_srid(geom) = 97261),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX legal_space_utility_network_historic_index_on_rowidentifier ON cadastre.legal_space_utility_network_historic (rowidentifier);
CREATE INDEX legal_space_utility_network_historic_index_on_geom ON cadastre.legal_space_utility_network_historic USING gist (geom);


DROP TRIGGER IF EXISTS __track_history ON cadastre.legal_space_utility_network CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON cadastre.legal_space_utility_network FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table cadastre.building_unit_type ----
DROP TABLE IF EXISTS cadastre.building_unit_type CASCADE;
CREATE TABLE cadastre.building_unit_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('t'),

    -- Internal constraints
    
    CONSTRAINT building_unit_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT building_unit_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.building_unit_type -- 
insert into cadastre.building_unit_type(code, display_value, status) values('individual', 'Individual::::Individuale', 'c');
insert into cadastre.building_unit_type(code, display_value, status) values('shared', 'Shared::::Condiviso', 'c');



--Table cadastre.area_unit_type ----
DROP TABLE IF EXISTS cadastre.area_unit_type CASCADE;
CREATE TABLE cadastre.area_unit_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('t'),

    -- Internal constraints
    
    CONSTRAINT area_unit_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT area_unit_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.area_unit_type -- 
insert into cadastre.area_unit_type(code, display_value, status) values('1501', 'Ropani::::रोपनी', 'c');
insert into cadastre.area_unit_type(code, display_value, status) values('1502', 'Bigha::::विगाहा', 'c');
insert into cadastre.area_unit_type(code, display_value, status) values('1503', 'SqM::::वगर् मिटर', 'c');
insert into cadastre.area_unit_type(code, display_value, status) values('1500', 'पहीरो प्रतिर्', 'x');
insert into cadastre.area_unit_type(code, display_value, status) values('1504', 'Blank::::.', 'x');



--Table cadastre.utility_network_type ----
DROP TABLE IF EXISTS cadastre.utility_network_type CASCADE;
CREATE TABLE cadastre.utility_network_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT utility_network_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT utility_network_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.utility_network_type -- 
insert into cadastre.utility_network_type(code, display_value, status) values('chemical', 'Chemicals::::Cimica', 'c');
insert into cadastre.utility_network_type(code, display_value, status) values('electricity', 'Electricity::::Elettricita', 'c');
insert into cadastre.utility_network_type(code, display_value, status) values('gas', 'Gas::::Gas', 'c');
insert into cadastre.utility_network_type(code, display_value, status) values('heating', 'Heating::::Riscaldamento', 'c');
insert into cadastre.utility_network_type(code, display_value, status) values('oil', 'Oil::::Carburante', 'c');
insert into cadastre.utility_network_type(code, display_value, status) values('telecommunication', 'Telecommunication::::Telecomunicazione', 'c');
insert into cadastre.utility_network_type(code, display_value, status) values('water', 'Water::::Acqua', 'c');



--Table application.application ----
DROP TABLE IF EXISTS application.application CASCADE;
CREATE TABLE application.application(
    id varchar(40) NOT NULL,
    nr varchar(15) NOT NULL,
    fy_code varchar(20) NOT NULL,
    agent_id varchar(40),
    contact_person_id varchar(40) NOT NULL,
    lodging_datetime timestamp NOT NULL DEFAULT (now()),
    expected_completion_date date NOT NULL DEFAULT (now()),
    assignee_id varchar(40),
    assigned_datetime timestamp,
    location GEOMETRY,
    CONSTRAINT enforce_dims_location CHECK (st_ndims(location) = 2),
    
            CONSTRAINT enforce_srid_location CHECK (st_srid(location) = 97261),
    CONSTRAINT enforce_geotype_location CHECK (geometrytype(location) = 'MULTIPOINT'::text OR location IS NULL),
    services_fee numeric(20, 2) NOT NULL DEFAULT (0),
    tax numeric(20, 2) NOT NULL DEFAULT (0),
    valuation_amount numeric(20, 2) NOT NULL DEFAULT (0),
    total_amount_paid numeric(20, 2) NOT NULL DEFAULT (0),
    fee_paid bool NOT NULL DEFAULT (false),
    payment_remarks varchar(255),
    action_code varchar(20) NOT NULL DEFAULT ('lodge'),
    action_notes varchar(255),
    status_code varchar(20) NOT NULL DEFAULT ('lodged'),
    receipt_number varchar(20),
    receipt_date date,
    office_code varchar(20),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT application_check_assigned CHECK ((assignee_id is null and assigned_datetime is null) or (assignee_id is not null and assigned_datetime is not null)),
    CONSTRAINT application_pkey PRIMARY KEY (id)
);


CREATE INDEX application_index_on_rowidentifier ON application.application (rowidentifier);
CREATE INDEX application_index_on_location ON application.application USING gist (location);

    
DROP TRIGGER IF EXISTS __track_changes ON application.application CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON application.application FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table application.application_historic used for the history of data of table application.application ---
DROP TABLE IF EXISTS application.application_historic CASCADE;
CREATE TABLE application.application_historic
(
    id varchar(40),
    nr varchar(15),
    fy_code varchar(20),
    agent_id varchar(40),
    contact_person_id varchar(40),
    lodging_datetime timestamp,
    expected_completion_date date,
    assignee_id varchar(40),
    assigned_datetime timestamp,
    location GEOMETRY,
    CONSTRAINT enforce_dims_location CHECK (st_ndims(location) = 2),
    
            CONSTRAINT enforce_srid_location CHECK (st_srid(location) = 97261),
    CONSTRAINT enforce_geotype_location CHECK (geometrytype(location) = 'MULTIPOINT'::text OR location IS NULL),
    services_fee numeric(20, 2),
    tax numeric(20, 2),
    valuation_amount numeric(20, 2),
    total_amount_paid numeric(20, 2),
    fee_paid bool,
    payment_remarks varchar(255),
    action_code varchar(20),
    action_notes varchar(255),
    status_code varchar(20),
    receipt_number varchar(20),
    receipt_date date,
    office_code varchar(20),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX application_historic_index_on_rowidentifier ON application.application_historic (rowidentifier);
CREATE INDEX application_historic_index_on_location ON application.application_historic USING gist (location);


DROP TRIGGER IF EXISTS __track_history ON application.application CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON application.application FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table application.request_type ----
DROP TABLE IF EXISTS application.request_type CASCADE;
CREATE TABLE application.request_type(
    code varchar(20) NOT NULL,
    request_category_code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('t'),
    nr_days_to_complete integer NOT NULL DEFAULT (0),
    base_fee numeric(20, 2) NOT NULL DEFAULT (0),
    area_base_fee numeric(20, 2) NOT NULL DEFAULT (0),
    value_base_fee numeric(20, 2) NOT NULL DEFAULT (0),
    nr_properties_required integer NOT NULL DEFAULT (0),
    notation_template varchar(1000),
    rrr_type_code varchar(20),
    type_action_code varchar(20),

    -- Internal constraints
    
    CONSTRAINT request_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT request_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table application.request_type -- 
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2001', 'registrationServices', 'Chhut Darta::::छुट जग्गा दतार्', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('cadastreChange', 'cadastreServices', 'Change to Cadastre::::किता काट्', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2002', 'registrationServices', 'Da Kha::::दाखिला खारेज', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2003', 'registrationServices', 'Hak Safi::::नामसारी', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2004', 'registrationServices', 'Ammendment::::संसोधन', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2005', 'registrationServices', 'हकसफी', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2007', 'registrationServices', 'Rajinama::::राजिनामा', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2008', 'registrationServices', 'Ha Ba::::बकस पत्र', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2009', 'registrationServices', 'Ansha Banda::::अंशवण्डा', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2010', 'registrationServices', 'Satta Patta::::सट्टा पटटा', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2011', 'registrationServices', 'Chhod Patra::::छोड पत्र', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2012', 'registrationServices', 'Darta Phari::::दतार् फारी', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2013', 'registrationServices', 'Sagol Nama::::सगोलनामा', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2014', 'registrationServices', 'Yekikaran::::श्रेष्ता एकिकरण', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2015', 'registrationServices', 'Old survey::::पूरानो नापी', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2016', 'registrationServices', 'New survey::::नयां नापी ४२', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2017', 'registrationServices', 'Bhog Bandhaki::::जग्गा दतार् नामसारी', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2018', 'registrationServices', 'अन्य', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2019', 'registrationServices', 'Blank::::।', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2020', 'registrationServices', 'Dan Patra::::दोहोरो दतार् हटाइएको', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2021', 'registrationServices', 'She Ba::::शेष पछिको वकसपत्र', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2022', 'registrationServices', 'Shresta Adhybadhik::::श्रेष्ता अध्यावधिक', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2023', 'registrationServices', 'Datra Namsari::::दतार् नामसारी', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2024', 'registrationServices', 'विकसित घडेरी', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2025', 'registrationServices', 'गुठि रैतानी नम्बरी', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2026', 'registrationServices', 'मोही दाखिल खारेज', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2027', 'registrationServices', 'चकला बन्धी', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2028', 'registrationServices', 'हा.सा.', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2031', 'registrationServices', 'लगतकट्टा', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2032', 'registrationServices', 'Lakha Bandhaki::::लख वन्धकी', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2033', 'registrationServices', 'Dristi Bandhaki::::दृíटी वन्धकी', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2034', 'registrationServices', 'Mila Patra::::मिला पत्र', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2035', 'registrationServices', 'Dan Patra::::दान पत्र', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2036', 'registrationServices', 'Ansa Bughayako Bharpai::::अंश बुझेको भरपाई', 'c', 1, 0, 0, 0, 1);
insert into application.request_type(code, request_category_code, display_value, status, nr_days_to_complete, base_fee, area_base_fee, value_base_fee, nr_properties_required) values('2037', 'registrationServices', 'तिनपुस्ते वकस पत्र', 'c', 1, 0, 0, 0, 1);



--Table application.request_category_type ----
DROP TABLE IF EXISTS application.request_category_type CASCADE;
CREATE TABLE application.request_category_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('t'),

    -- Internal constraints
    
    CONSTRAINT request_category_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT request_category_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table application.request_category_type -- 
insert into application.request_category_type(code, display_value, status) values('registrationServices', 'Registration Services::::Registration Services', 'c');
insert into application.request_category_type(code, display_value, status) values('informationServices', 'Information Services::::Information Services', 'c');
insert into application.request_category_type(code, display_value, status) values('cadastreServices', 'Cadastre services::::Cadastre services', 'c');
insert into application.request_category_type(code, display_value, status) values('2101', 'Land Transaction::::जग्गा कारोवार', 'x');
insert into application.request_category_type(code, display_value, status) values('2102', 'Floor Transaction::::तल्ला कारोवार', 'x');
insert into application.request_category_type(code, display_value, status) values('2103', 'Tenant Transaction::::मोही कारोवार', 'x');
insert into application.request_category_type(code, display_value, status) values('2104', 'Change Owner::::जग्गाधनी परिवतर्न', 'x');
insert into application.request_category_type(code, display_value, status) values('2105', 'Change Tenant::::मोही परिवतर्न', 'x');
insert into application.request_category_type(code, display_value, status) values('2106', 'Amendment::::संशोधन', 'x');
insert into application.request_category_type(code, display_value, status) values('2107', 'Merge Land Parcel::::जग्गा एकिकरण', 'x');



--Table application.service ----
DROP TABLE IF EXISTS application.service CASCADE;
CREATE TABLE application.service(
    id varchar(40) NOT NULL,
    application_id varchar(40),
    request_type_code varchar(20) NOT NULL,
    service_order integer NOT NULL DEFAULT (0),
    lodging_datetime timestamp NOT NULL DEFAULT (now()),
    expected_completion_date date NOT NULL,
    status_code varchar(20) NOT NULL DEFAULT ('lodged'),
    action_code varchar(20) NOT NULL DEFAULT ('lodge'),
    action_notes varchar(255),
    base_fee numeric(20, 2) NOT NULL DEFAULT (0),
    area_fee numeric(20, 2) NOT NULL DEFAULT (0),
    value_fee numeric(20, 2) NOT NULL DEFAULT (0),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT service_pkey PRIMARY KEY (id)
);


CREATE INDEX service_index_on_rowidentifier ON application.service (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON application.service CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON application.service FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table application.service_historic used for the history of data of table application.service ---
DROP TABLE IF EXISTS application.service_historic CASCADE;
CREATE TABLE application.service_historic
(
    id varchar(40),
    application_id varchar(40),
    request_type_code varchar(20),
    service_order integer,
    lodging_datetime timestamp,
    expected_completion_date date,
    status_code varchar(20),
    action_code varchar(20),
    action_notes varchar(255),
    base_fee numeric(20, 2),
    area_fee numeric(20, 2),
    value_fee numeric(20, 2),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX service_historic_index_on_rowidentifier ON application.service_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON application.service CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON application.service FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table party.party_role ----
DROP TABLE IF EXISTS party.party_role CASCADE;
CREATE TABLE party.party_role(
    party_id varchar(40) NOT NULL,
    type_code varchar(20) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT party_role_pkey PRIMARY KEY (party_id,type_code)
);


CREATE INDEX party_role_index_on_rowidentifier ON party.party_role (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON party.party_role CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON party.party_role FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table party.party_role_historic used for the history of data of table party.party_role ---
DROP TABLE IF EXISTS party.party_role_historic CASCADE;
CREATE TABLE party.party_role_historic
(
    party_id varchar(40),
    type_code varchar(20),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX party_role_historic_index_on_rowidentifier ON party.party_role_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON party.party_role CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON party.party_role FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table party.party_role_type ----
DROP TABLE IF EXISTS party.party_role_type CASCADE;
CREATE TABLE party.party_role_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL DEFAULT ('t'),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT party_role_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT party_role_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table party.party_role_type -- 
insert into party.party_role_type(code, display_value, status) values('conveyor', 'Conveyor::::Trasportatore', 'x');
insert into party.party_role_type(code, display_value, status) values('notary', 'Notary::::Notaio', 'c');
insert into party.party_role_type(code, display_value, status) values('writer', 'Writer::::Autore', 'x');
insert into party.party_role_type(code, display_value, status) values('surveyor', 'Surveyor::::Perito', 'x');
insert into party.party_role_type(code, display_value, status) values('certifiedSurveyor', 'Licenced Surveyor::::Perito con Licenza', 'c');
insert into party.party_role_type(code, display_value, status) values('bank', 'Bank::::Banca', 'c');
insert into party.party_role_type(code, display_value, status) values('moneyProvider', 'Money Provider::::Istituto Credito', 'c');
insert into party.party_role_type(code, display_value, status) values('employee', 'Employee::::Impiegato', 'x');
insert into party.party_role_type(code, display_value, status) values('farmer', 'Farmer::::Contadino', 'x');
insert into party.party_role_type(code, display_value, status) values('citizen', 'Citizen::::Cittadino', 'c');
insert into party.party_role_type(code, display_value, status) values('stateAdministrator', 'Registrar / Approving Surveyor::::Cancelleriere/ Perito Approvatore/', 'c');
insert into party.party_role_type(code, display_value, status, description) values('landOfficer', 'Land Officer::::Ufficiale del Registro Territoriale', 'c', 'Extension to LADM');
insert into party.party_role_type(code, display_value, status, description) values('lodgingAgent', 'Lodging Agent::::Richiedente Registrazione', 'c', 'Extension to LADM');
insert into party.party_role_type(code, display_value, status, description) values('powerOfAttorney', 'Power of Attorney::::Procuratore', 'c', 'Extension to LADM');
insert into party.party_role_type(code, display_value, status, description) values('transferee', 'Transferee (to)::::Avente Causa', 'c', 'Extension to LADM');
insert into party.party_role_type(code, display_value, status, description) values('transferor', 'Transferor (from)::::Dante Causa', 'c', 'Extension to LADM');
insert into party.party_role_type(code, display_value, status, description) values('applicant', 'Applicant', 'c', 'Extension to LADM');



--Table address.address ----
DROP TABLE IF EXISTS address.address CASCADE;
CREATE TABLE address.address(
    id varchar(40) NOT NULL,
    vdc_code varchar(20) NOT NULL,
    ward_no varchar(20),
    street varchar(50),
    description varchar(255),
    ext_address_id varchar(40),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT address_pkey PRIMARY KEY (id)
);


CREATE INDEX address_index_on_rowidentifier ON address.address (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON address.address CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON address.address FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table address.address_historic used for the history of data of table address.address ---
DROP TABLE IF EXISTS address.address_historic CASCADE;
CREATE TABLE address.address_historic
(
    id varchar(40),
    vdc_code varchar(20),
    ward_no varchar(20),
    street varchar(50),
    description varchar(255),
    ext_address_id varchar(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX address_historic_index_on_rowidentifier ON address.address_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON address.address CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON address.address FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table system.appuser ----
DROP TABLE IF EXISTS system.appuser CASCADE;
CREATE TABLE system.appuser(
    id varchar(40) NOT NULL,
    username varchar(40) NOT NULL,
    first_name varchar(30) NOT NULL,
    last_name varchar(30) NOT NULL,
    passwd varchar(100) NOT NULL DEFAULT (uuid_generate_v1()),
    active bool NOT NULL DEFAULT (true),
    description varchar(255),
    department_code varchar(20) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT appuser_username_unique UNIQUE (username),
    CONSTRAINT appuser_pkey PRIMARY KEY (id)
);


CREATE INDEX appuser_index_on_rowidentifier ON system.appuser (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON system.appuser CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON system.appuser FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table system.appuser_historic used for the history of data of table system.appuser ---
DROP TABLE IF EXISTS system.appuser_historic CASCADE;
CREATE TABLE system.appuser_historic
(
    id varchar(40),
    username varchar(40),
    first_name varchar(30),
    last_name varchar(30),
    passwd varchar(100),
    active bool,
    description varchar(255),
    department_code varchar(20),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX appuser_historic_index_on_rowidentifier ON system.appuser_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON system.appuser CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON system.appuser FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
 -- Data for the table system.appuser -- 
insert into system.appuser(id, username, first_name, last_name, passwd, active, department_code) values('test-id', 'test', 'Test', 'The BOSS', '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08', true, 'Lalitpur-001');



--Table cadastre.dimension_type ----
DROP TABLE IF EXISTS cadastre.dimension_type CASCADE;
CREATE TABLE cadastre.dimension_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('t'),

    -- Internal constraints
    
    CONSTRAINT dimension_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT dimension_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.dimension_type -- 
insert into cadastre.dimension_type(code, display_value, status) values('0D', '0D::::0D', 'c');
insert into cadastre.dimension_type(code, display_value, status) values('1D', '1D::::1D', 'c');
insert into cadastre.dimension_type(code, display_value, status) values('2D', '2D::::sD', 'c');
insert into cadastre.dimension_type(code, display_value, status) values('3D', '3D::::3D', 'c');
insert into cadastre.dimension_type(code, display_value, status) values('liminal', 'Liminal', 'x');



--Table party.communication_type ----
DROP TABLE IF EXISTS party.communication_type CASCADE;
CREATE TABLE party.communication_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL DEFAULT ('t'),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT communication_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT communication_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table party.communication_type -- 
insert into party.communication_type(code, display_value, status) values('eMail', 'e-Mail::::E-mail', 'c');
insert into party.communication_type(code, display_value, status) values('fax', 'Fax::::Fax', 'c');
insert into party.communication_type(code, display_value, status) values('post', 'Post::::Posta', 'c');
insert into party.communication_type(code, display_value, status) values('phone', 'Phone::::Telefono', 'c');
insert into party.communication_type(code, display_value, status) values('courier', 'Courier::::Corriere', 'c');



--Table source.presentation_form_type ----
DROP TABLE IF EXISTS source.presentation_form_type CASCADE;
CREATE TABLE source.presentation_form_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL DEFAULT ('t'),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT presentation_form_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT presentation_form_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table source.presentation_form_type -- 
insert into source.presentation_form_type(code, display_value, status) values('documentDigital', 'Digital Document::::Documento Digitale', 'c');
insert into source.presentation_form_type(code, display_value, status) values('documentHardcopy', 'Hardcopy Document::::Documento in Hardcopy', 'c');
insert into source.presentation_form_type(code, display_value, status) values('imageDigital', 'Digital Image::::Immagine Digitale', 'c');
insert into source.presentation_form_type(code, display_value, status) values('imageHardcopy', 'Hardcopy Image::::Immagine in Hardcopy', 'c');
insert into source.presentation_form_type(code, display_value, status) values('mapDigital', 'Digital Map::::Mappa Digitale', 'c');
insert into source.presentation_form_type(code, display_value, status) values('mapHardcopy', 'Hardcopy Map::::Mappa in Hardcopy', 'c');
insert into source.presentation_form_type(code, display_value, status) values('modelDigital', 'Digital Model::::Modello Digitale'',', 'c');
insert into source.presentation_form_type(code, display_value, status) values('modelHarcopy', 'Hardcopy Model::::Modello in Hardcopy', 'c');
insert into source.presentation_form_type(code, display_value, status) values('profileDigital', 'Digital Profile::::Profilo Digitale', 'c');
insert into source.presentation_form_type(code, display_value, status) values('profileHardcopy', 'Hardcopy Profile::::Profilo in Hardcopy', 'c');
insert into source.presentation_form_type(code, display_value, status) values('tableDigital', 'Digital Table::::Tabella Digitale', 'c');
insert into source.presentation_form_type(code, display_value, status) values('tableHardcopy', 'Hardcopy Table::::Tabella in Hardcopy', 'c');
insert into source.presentation_form_type(code, display_value, status) values('videoDigital', 'Digital Video::::Video Digitale'',', 'c');
insert into source.presentation_form_type(code, display_value, status) values('videoHardcopy', 'Hardcopy Video::::Video in Hardcopy', 'c');



--Table source.archive ----
DROP TABLE IF EXISTS source.archive CASCADE;
CREATE TABLE source.archive(
    id varchar(40) NOT NULL,
    name varchar(50) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT archive_pkey PRIMARY KEY (id)
);


CREATE INDEX archive_index_on_rowidentifier ON source.archive (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON source.archive CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON source.archive FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table source.archive_historic used for the history of data of table source.archive ---
DROP TABLE IF EXISTS source.archive_historic CASCADE;
CREATE TABLE source.archive_historic
(
    id varchar(40),
    name varchar(50),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX archive_historic_index_on_rowidentifier ON source.archive_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON source.archive CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON source.archive FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table application.application_action_type ----
DROP TABLE IF EXISTS application.application_action_type CASCADE;
CREATE TABLE application.application_action_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status_to_set varchar(20),
    status char(1) NOT NULL DEFAULT ('t'),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT application_action_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT application_action_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table application.application_action_type -- 
insert into application.application_action_type(code, display_value, status_to_set, status, description) values('lodge', 'Lodgement Notice Prepared::::Ricevuta della Registrazione Preparata', 'lodged', 'c', 'Lodgement notice is prepared (action is automatically logged when application details are saved for the first time::::La ricevuta della registrazione pronta');
insert into application.application_action_type(code, display_value, status, description) values('addDocument', 'Add document::::Documenti scannerizzati allegati alla pratica', 'c', 'Scanned Documents linked to Application (action is automatically logged when a new document is saved)::::Documenti scannerizzati allegati alla pratica');
insert into application.application_action_type(code, display_value, status_to_set, status, description) values('withdraw', 'Withdraw application::::Pratica Ritirata', 'anulled', 'c', 'Application withdrawn by Applicant (action is manually logged)::::Pratica Ritirata dal Richiedente');
insert into application.application_action_type(code, display_value, status_to_set, status, description) values('cancel', 'Cancel application::::Pratica cancellata', 'anulled', 'c', 'Application cancelled by Land Office (action is automatically logged when application is cancelled)::::Pratica cancellata da Ufficio Territoriale');
insert into application.application_action_type(code, display_value, status_to_set, status, description) values('requisition', 'Requisition:::Ulteriori Informazioni domandate dal richiedente', 'requisitioned', 'c', 'Further information requested from applicant (action is manually logged)::::Ulteriori Informazioni domandate dal richiedente');
insert into application.application_action_type(code, display_value, status, description) values('validateFailed', 'Quality Check Fails::::Controllo Qualita Fallito', 'c', 'Quality check fails (automatically logged when a critical business rule failure occurs)::::Controllo Qualita Fallito');
insert into application.application_action_type(code, display_value, status, description) values('validatePassed', 'Quality Check Passes::::Controllo Qualita Superato', 'c', 'Quality check passes (automatically logged when business rules are run without any critical failures)::::Controllo Qualita Superato');
insert into application.application_action_type(code, display_value, status_to_set, status, description) values('approve', 'Approve::::Approvata', 'approved', 'c', 'Application is approved (automatically logged when application is approved successively)::::Pratica approvata');
insert into application.application_action_type(code, display_value, status_to_set, status, description) values('archive', 'Archive::::Archiviata', 'completed', 'c', 'Paper application records are archived (action is manually logged)::::I fogli della pratica sono stati archiviati');
insert into application.application_action_type(code, display_value, status, description) values('despatch', 'Despatch::::Inviata', 'c', 'Application documents and new land office products are sent or collected by applicant (action is manually logged)::::I documenti della pratica e i nuovi prodotti da Ufficio Territoriale sono stati spediti o ritirati dal richiedente');
insert into application.application_action_type(code, display_value, status_to_set, status) values('lapse', 'Lapse::::ITALIANO', 'anulled', 'c');
insert into application.application_action_type(code, display_value, status) values('assign', 'Assign::::ITALIANO', 'c');
insert into application.application_action_type(code, display_value, status) values('unAssign', 'Unassign::::ITALIANO', 'c');
insert into application.application_action_type(code, display_value, status_to_set, status) values('resubmit', 'Resubmit::::ITALIANO', 'lodged', 'c');
insert into application.application_action_type(code, display_value, status, description) values('validate', 'Validate::::ITALIANO', 'c', 'The action validate does not leave a mark, because validateFailed and validateSucceded will be used instead when the validate is completed.');
insert into application.application_action_type(code, display_value, status, description) values('transfer', 'Transfer application between departments', 'c', 'Application transfered to the given department');



--Table application.service_status_type ----
DROP TABLE IF EXISTS application.service_status_type CASCADE;
CREATE TABLE application.service_status_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL DEFAULT ('t'),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT service_status_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT service_status_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table application.service_status_type -- 
insert into application.service_status_type(code, display_value, status, description) values('lodged', 'Lodged::::रेजि्ष्टर', 'c', 'Application for a service has been lodged and officially received by land office::::La pratica per un servizio, registrata e formalmente ricevuta da ufficio territoriale');
insert into application.service_status_type(code, display_value, status) values('completed', 'Completed::::पुर्ण', 'c');
insert into application.service_status_type(code, display_value, status) values('pending', 'Pending::::बाकि', 'c');
insert into application.service_status_type(code, display_value, status) values('cancelled', 'Cancelled::::खारेज', 'c');



--Table party.id_type ----
DROP TABLE IF EXISTS party.id_type CASCADE;
CREATE TABLE party.id_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL DEFAULT ('t'),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT id_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT id_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table party.id_type -- 
insert into party.id_type(code, display_value, status, description) values('nationalID', 'National ID::::Carta Identita Nazionale', 'c', 'The main person ID that exists in the country::::Il principale documento identificativo nel paese');
insert into party.id_type(code, display_value, status, description) values('nationalPassport', 'National Passport::::Passaporto Nazionale', 'c', 'A passport issued by the country::::Passaporto fornito dal paese');
insert into party.id_type(code, display_value, status, description) values('otherPassport', 'Other Passport::::Altro Passaporto', 'c', 'A passport issued by another country::::Passaporto Fornito da un altro paese');
insert into party.id_type(code, display_value, status, description) values('citizenship', 'Citizenship::::Citizenship', 'c', 'Citizenship::::Citizenship');



--Table application.service_action_type ----
DROP TABLE IF EXISTS application.service_action_type CASCADE;
CREATE TABLE application.service_action_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status_to_set varchar(20),
    status char(1) NOT NULL DEFAULT ('t'),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT service_action_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT service_action_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table application.service_action_type -- 
insert into application.service_action_type(code, display_value, status_to_set, status, description) values('lodge', 'Lodge::::रेजि्ष्टर', 'lodged', 'c', 'Application for service(s) is officially received by land office (action is automatically logged when application is saved for the first time)::::La pratica per i servizi formalmente ricevuta da ufficio territoriale');
insert into application.service_action_type(code, display_value, status_to_set, status, description) values('start', 'Start::::सुरु', 'pending', 'c', 'Provisional RRR Changes Made to Database as a result of application (action is automatically logged when a change is made to a rrr object)::::Apportate Modifiche Provvisorie di tipo RRR al Database come risultato della pratica');
insert into application.service_action_type(code, display_value, status_to_set, status, description) values('cancel', 'Cancel::::खारेज', 'cancelled', 'c', 'Service is cancelled by Land Office (action is automatically logged when a service is cancelled)::::Pratica cancellata da Ufficio Territoriale');
insert into application.service_action_type(code, display_value, status_to_set, status, description) values('complete', 'Complete::::पुर्ण', 'completed', 'c', 'Application is ready for approval (action is automatically logged when service is marked as complete::::Pratica pronta per approvazione');
insert into application.service_action_type(code, display_value, status_to_set, status, description) values('revert', 'Revert::::उल्टाउनु', 'pending', 'c', 'The status of the service has been reverted to pending from being completed (action is automatically logged when a service is reverted back for further work)::::ITALIANO');



--Table application.application_property ----
DROP TABLE IF EXISTS application.application_property CASCADE;
CREATE TABLE application.application_property(
    application_id varchar(40) NOT NULL,
    ba_unit_id varchar(40) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT application_property_pkey PRIMARY KEY (application_id,ba_unit_id)
);


CREATE INDEX application_property_index_on_rowidentifier ON application.application_property (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON application.application_property CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON application.application_property FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table application.application_property_historic used for the history of data of table application.application_property ---
DROP TABLE IF EXISTS application.application_property_historic CASCADE;
CREATE TABLE application.application_property_historic
(
    application_id varchar(40),
    ba_unit_id varchar(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX application_property_historic_index_on_rowidentifier ON application.application_property_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON application.application_property CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON application.application_property FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table application.application_uses_source ----
DROP TABLE IF EXISTS application.application_uses_source CASCADE;
CREATE TABLE application.application_uses_source(
    application_id varchar(40) NOT NULL,
    source_id varchar(40) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT application_uses_source_pkey PRIMARY KEY (application_id,source_id)
);


CREATE INDEX application_uses_source_index_on_rowidentifier ON application.application_uses_source (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON application.application_uses_source CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON application.application_uses_source FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table application.application_uses_source_historic used for the history of data of table application.application_uses_source ---
DROP TABLE IF EXISTS application.application_uses_source_historic CASCADE;
CREATE TABLE application.application_uses_source_historic
(
    application_id varchar(40),
    source_id varchar(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX application_uses_source_historic_index_on_rowidentifier ON application.application_uses_source_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON application.application_uses_source CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON application.application_uses_source FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table application.request_type_requires_source_type ----
DROP TABLE IF EXISTS application.request_type_requires_source_type CASCADE;
CREATE TABLE application.request_type_requires_source_type(
    source_type_code varchar(20) NOT NULL,
    request_type_code varchar(20) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT request_type_requires_source_type_pkey PRIMARY KEY (source_type_code,request_type_code)
);

    
--Table application.application_status_type ----
DROP TABLE IF EXISTS application.application_status_type CASCADE;
CREATE TABLE application.application_status_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL DEFAULT ('t'),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT application_status_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT application_status_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table application.application_status_type -- 
insert into application.application_status_type(code, display_value, status, description) values('lodged', 'Lodged::::Registrata', 'c', 'Application has been lodged and officially received by land office::::La pratica registrata e formalmente ricevuta da ufficio territoriale');
insert into application.application_status_type(code, display_value, status) values('approved', 'Approved::::ITALIANO', 'c');
insert into application.application_status_type(code, display_value, status) values('anulled', 'Anulled::::Anullato', 'c');
insert into application.application_status_type(code, display_value, status) values('completed', 'Completed::::ITALIANO', 'c');
insert into application.application_status_type(code, display_value, status) values('requisitioned', 'Requisitioned::::ITALIANO', 'c');



--Table document.document ----
DROP TABLE IF EXISTS document.document CASCADE;
CREATE TABLE document.document(
    id varchar(40) NOT NULL,
    nr varchar(15) NOT NULL,
    extension varchar(5) NOT NULL,
    body bytea NOT NULL,
    description varchar(100),
    office_code varchar(20),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT document_nr_unique UNIQUE (nr),
    CONSTRAINT document_pkey PRIMARY KEY (id)
);


CREATE INDEX document_index_on_rowidentifier ON document.document (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON document.document CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON document.document FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table document.document_historic used for the history of data of table document.document ---
DROP TABLE IF EXISTS document.document_historic CASCADE;
CREATE TABLE document.document_historic
(
    id varchar(40),
    nr varchar(15),
    extension varchar(5),
    body bytea,
    description varchar(100),
    office_code varchar(20),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX document_historic_index_on_rowidentifier ON document.document_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON document.document CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON document.document FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table system.setting ----
DROP TABLE IF EXISTS system.setting CASCADE;
CREATE TABLE system.setting(
    name varchar(50) NOT NULL,
    vl varchar(2000) NOT NULL,
    active bool NOT NULL DEFAULT (true),
    description varchar(555) NOT NULL,
    office_code varchar(20),

    -- Internal constraints
    
    CONSTRAINT setting_pkey PRIMARY KEY (name)
);

    
 -- Data for the table system.setting -- 
insert into system.setting(name, vl, active, description) values('map-srid', '2193', true, 'The srid of the geographic data that are administered in the system.');
insert into system.setting(name, vl, active, description) values('map-west', '1776400', true, 'The most west coordinate. It is used in the map control.');
insert into system.setting(name, vl, active, description) values('map-south', '5919888', true, 'The most south coordinate. It is used in the map control.');
insert into system.setting(name, vl, active, description) values('map-east', '1795771', true, 'The most east coordinate. It is used in the map control.');
insert into system.setting(name, vl, active, description) values('map-north', '5932259', true, 'The most north coordinate. It is used in the map control.');
insert into system.setting(name, vl, active, description) values('map-tolerance', '0.001', true, 'The tolerance that is used while snapping geometries to each other. If two points are within this distance are considered being in the same location.');
insert into system.setting(name, vl, active, description) values('map-shift-tolerance-rural', '20', true, 'The shift tolerance of boundary points used in cadastre change in rural areas.');
insert into system.setting(name, vl, active, description) values('map-shift-tolerance-urban', '5', true, 'The shift tolerance of boundary points used in cadastre change in urban areas.');



--Table system.appuser_setting ----
DROP TABLE IF EXISTS system.appuser_setting CASCADE;
CREATE TABLE system.appuser_setting(
    user_id varchar(40) NOT NULL,
    name varchar(50) NOT NULL,
    vl varchar(2000) NOT NULL,
    active bool NOT NULL DEFAULT (true),

    -- Internal constraints
    
    CONSTRAINT appuser_setting_pkey PRIMARY KEY (user_id,name)
);

    
--Table system.language ----
DROP TABLE IF EXISTS system.language CASCADE;
CREATE TABLE system.language(
    code varchar(7) NOT NULL,
    display_value varchar(250) NOT NULL,
    active bool NOT NULL DEFAULT (true),
    is_default bool NOT NULL DEFAULT (false),
    item_order integer NOT NULL DEFAULT (1),

    -- Internal constraints
    
    CONSTRAINT language_display_value_unique UNIQUE (display_value),
    CONSTRAINT language_pkey PRIMARY KEY (code)
);

    
 -- Data for the table system.language -- 
insert into system.language(code, display_value, active, is_default, item_order) values('en', 'English::::ईगलिस', true, true, 1);
insert into system.language(code, display_value, active, is_default, item_order) values('np', 'Nepali::::नैपाली', true, false, 2);



--Table system.config_map_layer ----
DROP TABLE IF EXISTS system.config_map_layer CASCADE;
CREATE TABLE system.config_map_layer(
    name varchar(50) NOT NULL,
    title varchar(100) NOT NULL,
    type_code varchar(20) NOT NULL,
    wms_url varchar(500),
    wms_layers varchar(500),
    pojo_query_name varchar(100) NOT NULL,
    pojo_structure varchar(500),
    pojo_query_name_for_select varchar(100) NOT NULL,
    shape_location varchar(500),
    style varchar(4000),
    active bool NOT NULL DEFAULT (true),
    item_order integer NOT NULL DEFAULT (0),

    -- Internal constraints
    
    CONSTRAINT config_map_layer_style_required CHECK (case when type_code = 'wms' then wms_url is not null and wms_layers is not null when type_code = 'pojo' then pojo_query_name is not null and pojo_structure is not null and style is not null when type_code = 'shape' then shape_location is not null and style is not null end),
    CONSTRAINT config_map_layer_title_unique UNIQUE (title),
    CONSTRAINT config_map_layer_pkey PRIMARY KEY (name)
);

    
 -- Data for the table system.config_map_layer -- 
insert into system.config_map_layer(name, title, type_code, pojo_query_name, pojo_structure, pojo_query_name_for_select, style, active, item_order) values('parcels', 'Parcels::::ITALIANO', 'pojo', 'SpatialResult.getParcels', 'theGeom:Polygon,label:""', 'dynamic.informationtool.get_parcel', 'parcel.xml', true, 1);
insert into system.config_map_layer(name, title, type_code, pojo_query_name, pojo_structure, pojo_query_name_for_select, style, active, item_order) values('pending-parcels', 'Pending parcels::::ITALIANO', 'pojo', 'SpatialResult.getParcelsPending', 'theGeom:Polygon,label:""', 'dynamic.informationtool.get_parcel_pending', 'pending_parcels.xml', true, 2);
insert into system.config_map_layer(name, title, type_code, pojo_query_name, pojo_structure, pojo_query_name_for_select, style, active, item_order) values('roads', 'Roads::::ITALIANO', 'pojo', 'SpatialResult.getRoads', 'theGeom:MultiPolygon,label:""', 'dynamic.informationtool.get_road', 'road.xml', true, 7);
insert into system.config_map_layer(name, title, type_code, pojo_query_name, pojo_structure, pojo_query_name_for_select, style, active, item_order) values('survey-controls', 'Survey controls::::ITALIANO', 'pojo', 'SpatialResult.getSurveyControls', 'theGeom:Point,label:""', 'dynamic.informationtool.get_survey_control', 'survey_control.xml', true, 8);
insert into system.config_map_layer(name, title, type_code, pojo_query_name, pojo_structure, pojo_query_name_for_select, style, active, item_order) values('place-names', 'Places names::::ITALIANO', 'pojo', 'SpatialResult.getPlaceNames', 'theGeom:Point,label:""', 'dynamic.informationtool.get_place_name', 'place_name.xml', true, 5);
insert into system.config_map_layer(name, title, type_code, pojo_query_name, pojo_structure, pojo_query_name_for_select, style, active, item_order) values('applications', 'Applications::::ITALIANO', 'pojo', 'SpatialResult.getApplications', 'theGeom:MultiPoint,label:""', 'dynamic.informationtool.get_application', 'application.xml', true, 6);
insert into system.config_map_layer(name, title, type_code, pojo_query_name, pojo_structure, pojo_query_name_for_select, style, active, item_order) values('constructions', 'constructions::::ITALIANO', 'pojo', 'SpatialResult.getconstructions', 'theGeom:Polygon,label:""', 'dynamic.informationtool.get_construction', 'construction.xml', true, 3);
insert into system.config_map_layer(name, title, type_code, pojo_query_name, pojo_structure, pojo_query_name_for_select, style, active, item_order) values('segments', 'segments::::segments', 'pojo', 'SpatialResult.getsegments', 'theGeom:LineString,label:""', 'dynamic.informationtool.get_segment', 'segment.xml', true, 4);



--Table system.config_map_layer_type ----
DROP TABLE IF EXISTS system.config_map_layer_type CASCADE;
CREATE TABLE system.config_map_layer_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL,
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT config_map_layer_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT config_map_layer_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table system.config_map_layer_type -- 
insert into system.config_map_layer_type(code, display_value, status) values('wms', 'WMS server with layers::::Server WMS con layer', 'c');
insert into system.config_map_layer_type(code, display_value, status) values('shape', 'Shapefile::::Shapefile', 'c');
insert into system.config_map_layer_type(code, display_value, status) values('pojo', 'Pojo layer::::Pojo layer', 'c');



--Table administrative.ba_unit_as_party ----
DROP TABLE IF EXISTS administrative.ba_unit_as_party CASCADE;
CREATE TABLE administrative.ba_unit_as_party(
    ba_unit_id varchar(40) NOT NULL,
    party_id varchar(40) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT ba_unit_as_party_pkey PRIMARY KEY (ba_unit_id,party_id)
);

    
--Table transaction.reg_status_type ----
DROP TABLE IF EXISTS transaction.reg_status_type CASCADE;
CREATE TABLE transaction.reg_status_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT reg_status_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT reg_status_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table transaction.reg_status_type -- 
insert into transaction.reg_status_type(code, display_value, status) values('current', 'Current', 'c');
insert into transaction.reg_status_type(code, display_value, status) values('pending', 'Pending', 'c');
insert into transaction.reg_status_type(code, display_value, status) values('historic', 'Historic', 'c');
insert into transaction.reg_status_type(code, display_value, status) values('previous', 'Previous', 'c');



--Table system.br ----
DROP TABLE IF EXISTS system.br CASCADE;
CREATE TABLE system.br(
    id varchar(100) NOT NULL,
    display_name varchar(250) NOT NULL DEFAULT (uuid_generate_v1()),
    technical_type_code varchar(20) NOT NULL,
    feedback varchar(2000),
    description varchar(1000),
    technical_description varchar(1000),
    office_code varchar(20),

    -- Internal constraints
    
    CONSTRAINT br_display_name_unique UNIQUE (display_name),
    CONSTRAINT br_pkey PRIMARY KEY (id)
);

    
--Table system.br_technical_type ----
DROP TABLE IF EXISTS system.br_technical_type CASCADE;
CREATE TABLE system.br_technical_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL,
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT br_technical_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT br_technical_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table system.br_technical_type -- 
insert into system.br_technical_type(code, display_value, status, description) values('sql', 'SQL::::SQL', 'c', 'The rule definition is based in sql and it is executed by the database engine.');
insert into system.br_technical_type(code, display_value, status, description) values('drools', 'Drools::::Drools', 'c', 'The rule definition is based on Drools engine.');



--Table system.br_validation ----
DROP TABLE IF EXISTS system.br_validation CASCADE;
CREATE TABLE system.br_validation(
    id varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    br_id varchar(100) NOT NULL,
    target_code varchar(20) NOT NULL,
    target_application_moment varchar(20),
    target_service_moment varchar(20),
    target_reg_moment varchar(20),
    target_request_type_code varchar(20),
    target_rrr_type_code varchar(20),
    severity_code varchar(20) NOT NULL,
    order_of_execution integer NOT NULL DEFAULT (0),

    -- Internal constraints
    
    CONSTRAINT br_validation_service_request_type_valid CHECK (target_request_type_code is null or (target_request_type_code is not null and target_code != 'application')),
    CONSTRAINT br_validation_rrr_rrr_type_valid CHECK (target_rrr_type_code is null or (target_rrr_type_code is not null and target_code = 'rrr')),
    CONSTRAINT br_validation_app_moment_unique UNIQUE (br_id, target_code, target_application_moment),
    CONSTRAINT br_validation_service_moment_unique UNIQUE (br_id, target_code, target_service_moment),
    CONSTRAINT br_validation_reg_moment_unique UNIQUE (br_id, target_code, target_reg_moment),
    CONSTRAINT br_validation_service_moment_valid CHECK (target_code!= 'service' or (target_code = 'service' and target_application_moment is null and target_reg_moment is null)),
    CONSTRAINT br_validation_application_moment_valid CHECK (target_code!= 'application' or (target_code = 'application' and target_service_moment is null and target_reg_moment is null)),
    CONSTRAINT br_validation_reg_moment_valid CHECK (target_code in ( 'application', 'service') or (target_code not in ( 'application', 'service') and target_service_moment is null and target_application_moment is null)),
    CONSTRAINT br_validation_pkey PRIMARY KEY (id)
);

    
--Table system.br_definition ----
DROP TABLE IF EXISTS system.br_definition CASCADE;
CREATE TABLE system.br_definition(
    br_id varchar(100) NOT NULL,
    active_from date NOT NULL,
    active_until date NOT NULL DEFAULT ('infinity'),
    body varchar(4000) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT br_definition_pkey PRIMARY KEY (br_id,active_from)
);

    
--Table system.br_severity_type ----
DROP TABLE IF EXISTS system.br_severity_type CASCADE;
CREATE TABLE system.br_severity_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL,
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT br_severity_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT br_severity_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table system.br_severity_type -- 
insert into system.br_severity_type(code, display_value, status) values('critical', 'Critical', 'c');
insert into system.br_severity_type(code, display_value, status) values('medium', 'Medium', 'c');
insert into system.br_severity_type(code, display_value, status) values('warning', 'Warning', 'c');



--Table system.br_validation_target_type ----
DROP TABLE IF EXISTS system.br_validation_target_type CASCADE;
CREATE TABLE system.br_validation_target_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL,
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT br_validation_target_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT br_validation_target_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table system.br_validation_target_type -- 
insert into system.br_validation_target_type(code, display_value, status, description) values('application', 'Application::::ITALIANO', 'c', 'The target of the validation is the application. It accepts one parameter {id} which is the application id.');
insert into system.br_validation_target_type(code, display_value, status, description) values('service', 'Service::::ITALIANO', 'c', 'The target of the validation is the service. It accepts one parameter {id} which is the service id.');
insert into system.br_validation_target_type(code, display_value, status, description) values('rrr', 'Right or Restriction::::ITALIANO', 'c', 'The target of the validation is the rrr. It accepts one parameter {id} which is the rrr id. ');
insert into system.br_validation_target_type(code, display_value, status, description) values('ba_unit', 'Administrative Unit::::ITALIANO', 'c', 'The target of the validation is the ba_unit. It accepts one parameter {id} which is the ba_unit id.');
insert into system.br_validation_target_type(code, display_value, status, description) values('source', 'Source::::ITALIANO', 'c', 'The target of the validation is the source. It accepts one parameter {id} which is the source id.');
insert into system.br_validation_target_type(code, display_value, status, description) values('cadastre_object', 'Cadastre Object::::ITALIANO', 'c', 'The target of the validation is the transaction related with the cadastre change. It accepts one parameter {id} which is the transaction id.');



--Table cadastre.cadastre_object_type ----
DROP TABLE IF EXISTS cadastre.cadastre_object_type CASCADE;
CREATE TABLE cadastre.cadastre_object_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT cadastre_object_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT cadastre_object_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.cadastre_object_type -- 
insert into cadastre.cadastre_object_type(code, display_value, description, status) values('parcel', 'Parcel::::ITALIANO', '', 'c');
insert into cadastre.cadastre_object_type(code, display_value, description, status) values('buildingUnit', 'Building Unit::::ITALIANO', '', 'c');
insert into cadastre.cadastre_object_type(code, display_value, description, status) values('utilityNetwork', 'Utility Network::::ITALIANO', '', 'c');
insert into cadastre.cadastre_object_type(code, display_value, description, status) values('segment', 'Segment::::Segment', '', 'c');
insert into cadastre.cadastre_object_type(code, display_value, description, status) values('construction', 'Construction::Construction', '', 'c');



--Table cadastre.cadastre_object ----
DROP TABLE IF EXISTS cadastre.cadastre_object CASCADE;
CREATE TABLE cadastre.cadastre_object(
    id varchar(40) NOT NULL,
    type_code varchar(20) DEFAULT ('parcel'),
    map_sheet_id varchar(40),
    map_sheet_id2 varchar(40),
    map_sheet_id3 varchar(40),
    map_sheet_id4 varchar(40),
    dataset_id varchar(40),
    building_unit_type_code varchar(20),
    approval_datetime timestamp,
    historic_datetime timestamp,
    name_firstpart varchar(20) NOT NULL,
    name_lastpart varchar(50) NOT NULL,
    status_code varchar(20) NOT NULL DEFAULT ('pending'),
    geom_polygon GEOMETRY,
    CONSTRAINT enforce_dims_geom_polygon CHECK (st_ndims(geom_polygon) = 2),
    
            CONSTRAINT enforce_srid_geom_polygon CHECK (st_srid(geom_polygon) = 97261),
    CONSTRAINT enforce_geotype_geom_polygon CHECK (geometrytype(geom_polygon) = 'POLYGON'::text OR geom_polygon IS NULL),
    transaction_id varchar(40) NOT NULL,
    parcel_no varchar(10),
    official_area numeric(19, 4) DEFAULT (0),
    area_unit_type_code varchar(20),
    parcel_note varchar(255),
    land_type_code varchar(20),
    land_use_code varchar(20),
    land_class_code varchar(20),
    address_id varchar(40),
    office_code varchar(20) NOT NULL,
    fy_code varchar(20) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT cadastre_object_pkey PRIMARY KEY (id)
);


CREATE INDEX cadastre_object_index_on_rowidentifier ON cadastre.cadastre_object (rowidentifier);
CREATE INDEX cadastre_object_index_on_geom_polygon ON cadastre.cadastre_object USING gist (geom_polygon);

    
DROP TRIGGER IF EXISTS __track_changes ON cadastre.cadastre_object CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON cadastre.cadastre_object FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table cadastre.cadastre_object_historic used for the history of data of table cadastre.cadastre_object ---
DROP TABLE IF EXISTS cadastre.cadastre_object_historic CASCADE;
CREATE TABLE cadastre.cadastre_object_historic
(
    id varchar(40),
    type_code varchar(20),
    map_sheet_id varchar(40),
    map_sheet_id2 varchar(40),
    map_sheet_id3 varchar(40),
    map_sheet_id4 varchar(40),
    dataset_id varchar(40),
    building_unit_type_code varchar(20),
    approval_datetime timestamp,
    historic_datetime timestamp,
    name_firstpart varchar(20),
    name_lastpart varchar(50),
    status_code varchar(20),
    geom_polygon GEOMETRY,
    CONSTRAINT enforce_dims_geom_polygon CHECK (st_ndims(geom_polygon) = 2),
    
            CONSTRAINT enforce_srid_geom_polygon CHECK (st_srid(geom_polygon) = 97261),
    CONSTRAINT enforce_geotype_geom_polygon CHECK (geometrytype(geom_polygon) = 'POLYGON'::text OR geom_polygon IS NULL),
    transaction_id varchar(40),
    parcel_no varchar(10),
    official_area numeric(19, 4),
    area_unit_type_code varchar(20),
    parcel_note varchar(255),
    land_type_code varchar(20),
    land_use_code varchar(20),
    land_class_code varchar(20),
    address_id varchar(40),
    office_code varchar(20),
    fy_code varchar(20),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX cadastre_object_historic_index_on_rowidentifier ON cadastre.cadastre_object_historic (rowidentifier);
CREATE INDEX cadastre_object_historic_index_on_geom_polygon ON cadastre.cadastre_object_historic USING gist (geom_polygon);


DROP TRIGGER IF EXISTS __track_history ON cadastre.cadastre_object CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON cadastre.cadastre_object FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table administrative.ba_unit_rel_type ----
DROP TABLE IF EXISTS administrative.ba_unit_rel_type CASCADE;
CREATE TABLE administrative.ba_unit_rel_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT ba_unit_rel_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT ba_unit_rel_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table administrative.ba_unit_rel_type -- 
insert into administrative.ba_unit_rel_type(code, display_value, description, status) values('split', 'Splitting', 'Parcel splittiing', 'c');
insert into administrative.ba_unit_rel_type(code, display_value, description, status) values('merge', 'Merging', 'Parcel merging', 'c');



--Table administrative.notation ----
DROP TABLE IF EXISTS administrative.notation CASCADE;
CREATE TABLE administrative.notation(
    id varchar(40) NOT NULL,
    ba_unit_id varchar(40),
    rrr_id varchar(40),
    transaction_id varchar(40) NOT NULL,
    reference_nr varchar(15) NOT NULL,
    notation_text varchar(1000),
    status_code varchar(20) NOT NULL DEFAULT ('pending'),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT notation_pkey PRIMARY KEY (id)
);


CREATE INDEX notation_index_on_rowidentifier ON administrative.notation (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON administrative.notation CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON administrative.notation FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table administrative.notation_historic used for the history of data of table administrative.notation ---
DROP TABLE IF EXISTS administrative.notation_historic CASCADE;
CREATE TABLE administrative.notation_historic
(
    id varchar(40),
    ba_unit_id varchar(40),
    rrr_id varchar(40),
    transaction_id varchar(40),
    reference_nr varchar(15),
    notation_text varchar(1000),
    status_code varchar(20),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX notation_historic_index_on_rowidentifier ON administrative.notation_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON administrative.notation CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON administrative.notation FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table administrative.rrr_share ----
DROP TABLE IF EXISTS administrative.rrr_share CASCADE;
CREATE TABLE administrative.rrr_share(
    rrr_id varchar(40) NOT NULL,
    id varchar(40) NOT NULL,
    nominator smallint NOT NULL,
    denominator smallint NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT rrr_share_pkey PRIMARY KEY (rrr_id,id)
);


CREATE INDEX rrr_share_index_on_rowidentifier ON administrative.rrr_share (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON administrative.rrr_share CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON administrative.rrr_share FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table administrative.rrr_share_historic used for the history of data of table administrative.rrr_share ---
DROP TABLE IF EXISTS administrative.rrr_share_historic CASCADE;
CREATE TABLE administrative.rrr_share_historic
(
    rrr_id varchar(40),
    id varchar(40),
    nominator smallint,
    denominator smallint,
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX rrr_share_historic_index_on_rowidentifier ON administrative.rrr_share_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON administrative.rrr_share CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON administrative.rrr_share FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table administrative.party_for_rrr ----
DROP TABLE IF EXISTS administrative.party_for_rrr CASCADE;
CREATE TABLE administrative.party_for_rrr(
    rrr_id varchar(40) NOT NULL,
    party_id varchar(40) NOT NULL,
    share_id varchar(40),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT party_for_rrr_pkey PRIMARY KEY (rrr_id,party_id)
);


CREATE INDEX party_for_rrr_index_on_rowidentifier ON administrative.party_for_rrr (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON administrative.party_for_rrr CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON administrative.party_for_rrr FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table administrative.party_for_rrr_historic used for the history of data of table administrative.party_for_rrr ---
DROP TABLE IF EXISTS administrative.party_for_rrr_historic CASCADE;
CREATE TABLE administrative.party_for_rrr_historic
(
    rrr_id varchar(40),
    party_id varchar(40),
    share_id varchar(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX party_for_rrr_historic_index_on_rowidentifier ON administrative.party_for_rrr_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON administrative.party_for_rrr CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON administrative.party_for_rrr FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table transaction.transaction ----
DROP TABLE IF EXISTS transaction.transaction CASCADE;
CREATE TABLE transaction.transaction(
    id varchar(40) NOT NULL,
    from_service_id varchar(40),
    status_code varchar(20) NOT NULL DEFAULT ('pending'),
    approval_datetime timestamp,
    office_code varchar(20),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT transaction_from_service_id_unique UNIQUE (from_service_id),
    CONSTRAINT transaction_pkey PRIMARY KEY (id)
);


CREATE INDEX transaction_index_on_rowidentifier ON transaction.transaction (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON transaction.transaction CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON transaction.transaction FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table transaction.transaction_historic used for the history of data of table transaction.transaction ---
DROP TABLE IF EXISTS transaction.transaction_historic CASCADE;
CREATE TABLE transaction.transaction_historic
(
    id varchar(40),
    from_service_id varchar(40),
    status_code varchar(20),
    approval_datetime timestamp,
    office_code varchar(20),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX transaction_historic_index_on_rowidentifier ON transaction.transaction_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON transaction.transaction CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON transaction.transaction FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table transaction.transaction_status_type ----
DROP TABLE IF EXISTS transaction.transaction_status_type CASCADE;
CREATE TABLE transaction.transaction_status_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT transaction_status_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT transaction_status_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table transaction.transaction_status_type -- 
insert into transaction.transaction_status_type(code, display_value, status) values('approved', 'Approved::::Approvata', 'c');
insert into transaction.transaction_status_type(code, display_value, status) values('cancelled', 'CancelledApproved::::Cancellata', 'c');
insert into transaction.transaction_status_type(code, display_value, status) values('pending', 'Pending::::In Attesa', 'c');
insert into transaction.transaction_status_type(code, display_value, status) values('completed', 'Completed::::ITALIANO', 'c');



--Table application.type_action ----
DROP TABLE IF EXISTS application.type_action CASCADE;
CREATE TABLE application.type_action(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('t'),

    -- Internal constraints
    
    CONSTRAINT type_action_display_value_unique UNIQUE (display_value),
    CONSTRAINT type_action_pkey PRIMARY KEY (code)
);

    
 -- Data for the table application.type_action -- 
insert into application.type_action(code, display_value, status) values('new', 'New::::ITALIANO', 'c');
insert into application.type_action(code, display_value, status) values('vary', 'Vary::::ITALIANO', 'c');
insert into application.type_action(code, display_value, status) values('cancel', 'Cancel::::ITALIANO', 'c');



--Table cadastre.cadastre_object_target ----
DROP TABLE IF EXISTS cadastre.cadastre_object_target CASCADE;
CREATE TABLE cadastre.cadastre_object_target(
    transaction_id varchar(40) NOT NULL,
    cadastre_object_id varchar(40) NOT NULL,
    geom_polygon GEOMETRY,
    CONSTRAINT enforce_dims_geom_polygon CHECK (st_ndims(geom_polygon) = 2),
    
            CONSTRAINT enforce_srid_geom_polygon CHECK (st_srid(geom_polygon) = 97261),
    CONSTRAINT enforce_geotype_geom_polygon CHECK (geometrytype(geom_polygon) = 'POLYGON'::text OR geom_polygon IS NULL),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT cadastre_object_target_pkey PRIMARY KEY (transaction_id,cadastre_object_id)
);


CREATE INDEX cadastre_object_target_index_on_rowidentifier ON cadastre.cadastre_object_target (rowidentifier);
CREATE INDEX cadastre_object_target_index_on_geom_polygon ON cadastre.cadastre_object_target USING gist (geom_polygon);

    
DROP TRIGGER IF EXISTS __track_changes ON cadastre.cadastre_object_target CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON cadastre.cadastre_object_target FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table cadastre.cadastre_object_target_historic used for the history of data of table cadastre.cadastre_object_target ---
DROP TABLE IF EXISTS cadastre.cadastre_object_target_historic CASCADE;
CREATE TABLE cadastre.cadastre_object_target_historic
(
    transaction_id varchar(40),
    cadastre_object_id varchar(40),
    geom_polygon GEOMETRY,
    CONSTRAINT enforce_dims_geom_polygon CHECK (st_ndims(geom_polygon) = 2),
    
            CONSTRAINT enforce_srid_geom_polygon CHECK (st_srid(geom_polygon) = 97261),
    CONSTRAINT enforce_geotype_geom_polygon CHECK (geometrytype(geom_polygon) = 'POLYGON'::text OR geom_polygon IS NULL),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX cadastre_object_target_historic_index_on_rowidentifier ON cadastre.cadastre_object_target_historic (rowidentifier);
CREATE INDEX cadastre_object_target_historic_index_on_geom_polygon ON cadastre.cadastre_object_target_historic USING gist (geom_polygon);


DROP TRIGGER IF EXISTS __track_history ON cadastre.cadastre_object_target CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON cadastre.cadastre_object_target FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table party.gender_type ----
DROP TABLE IF EXISTS party.gender_type CASCADE;
CREATE TABLE party.gender_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL DEFAULT ('t'),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT gender_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT gender_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table party.gender_type -- 
insert into party.gender_type(code, display_value, status) values('male', 'Male', 'c');
insert into party.gender_type(code, display_value, status) values('female', 'Female', 'c');



--Table cadastre.survey_point ----
DROP TABLE IF EXISTS cadastre.survey_point CASCADE;
CREATE TABLE cadastre.survey_point(
    transaction_id varchar(40) NOT NULL,
    id varchar(40) NOT NULL,
    boundary bool NOT NULL DEFAULT (true),
    geom GEOMETRY NOT NULL,
    CONSTRAINT enforce_dims_geom CHECK (st_ndims(geom) = 2),
    
            CONSTRAINT enforce_srid_geom CHECK (st_srid(geom) = 97261),
    CONSTRAINT enforce_geotype_geom CHECK (geometrytype(geom) = 'POINT'::text OR geom IS NULL),
    original_geom GEOMETRY NOT NULL,
    CONSTRAINT enforce_dims_original_geom CHECK (st_ndims(original_geom) = 2),
    
            CONSTRAINT enforce_srid_original_geom CHECK (st_srid(original_geom) = 97261),
    CONSTRAINT enforce_geotype_original_geom CHECK (geometrytype(original_geom) = 'POINT'::text OR original_geom IS NULL),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT survey_point_pkey PRIMARY KEY (transaction_id,id)
);


CREATE INDEX survey_point_index_on_rowidentifier ON cadastre.survey_point (rowidentifier);
CREATE INDEX survey_point_index_on_geom ON cadastre.survey_point USING gist (geom);
CREATE INDEX survey_point_index_on_original_geom ON cadastre.survey_point USING gist (original_geom);

    
DROP TRIGGER IF EXISTS __track_changes ON cadastre.survey_point CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON cadastre.survey_point FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table cadastre.survey_point_historic used for the history of data of table cadastre.survey_point ---
DROP TABLE IF EXISTS cadastre.survey_point_historic CASCADE;
CREATE TABLE cadastre.survey_point_historic
(
    transaction_id varchar(40),
    id varchar(40),
    boundary bool,
    geom GEOMETRY,
    CONSTRAINT enforce_dims_geom CHECK (st_ndims(geom) = 2),
    
            CONSTRAINT enforce_srid_geom CHECK (st_srid(geom) = 97261),
    CONSTRAINT enforce_geotype_geom CHECK (geometrytype(geom) = 'POINT'::text OR geom IS NULL),
    original_geom GEOMETRY,
    CONSTRAINT enforce_dims_original_geom CHECK (st_ndims(original_geom) = 2),
    
            CONSTRAINT enforce_srid_original_geom CHECK (st_srid(original_geom) = 97261),
    CONSTRAINT enforce_geotype_original_geom CHECK (geometrytype(original_geom) = 'POINT'::text OR original_geom IS NULL),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX survey_point_historic_index_on_rowidentifier ON cadastre.survey_point_historic (rowidentifier);
CREATE INDEX survey_point_historic_index_on_geom ON cadastre.survey_point_historic USING gist (geom);
CREATE INDEX survey_point_historic_index_on_original_geom ON cadastre.survey_point_historic USING gist (original_geom);


DROP TRIGGER IF EXISTS __track_history ON cadastre.survey_point CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON cadastre.survey_point FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table transaction.transaction_source ----
DROP TABLE IF EXISTS transaction.transaction_source CASCADE;
CREATE TABLE transaction.transaction_source(
    transaction_id varchar(40) NOT NULL,
    source_id varchar(40) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT transaction_source_pkey PRIMARY KEY (transaction_id,source_id)
);


CREATE INDEX transaction_source_index_on_rowidentifier ON transaction.transaction_source (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON transaction.transaction_source CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON transaction.transaction_source FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table transaction.transaction_source_historic used for the history of data of table transaction.transaction_source ---
DROP TABLE IF EXISTS transaction.transaction_source_historic CASCADE;
CREATE TABLE transaction.transaction_source_historic
(
    transaction_id varchar(40),
    source_id varchar(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX transaction_source_historic_index_on_rowidentifier ON transaction.transaction_source_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON transaction.transaction_source CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON transaction.transaction_source FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table system.approle ----
DROP TABLE IF EXISTS system.approle CASCADE;
CREATE TABLE system.approle(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL,
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT approle_display_value_unique UNIQUE (display_value),
    CONSTRAINT approle_pkey PRIMARY KEY (code)
);

    
 -- Data for the table system.approle -- 
insert into system.approle(code, display_value, status, description) values('ApplnView', 'Search and View Applications', 'c', 'Search and view applications');
insert into system.approle(code, display_value, status, description) values('ApplnCreate', 'Lodge new Applications', 'c', 'Lodge new Applications');
insert into system.approle(code, display_value, status, description) values('ApplnStatus', 'Generate and View Status Report', 'c', 'Generate and View Status Report');
insert into system.approle(code, display_value, status, description) values('ApplnAssignDeprt', 'Assign Applications to Department staff', 'c', 'Able to assign (unassigned) applications to department staff');
insert into system.approle(code, display_value, status, description) values('ApplnAssignAll', 'Assign Applications to all users in office', 'c', 'Able to assign (unassigned) applications to any user in office');
insert into system.approle(code, display_value, status, description) values('CancelService', 'Cancel Service', 'c', 'Cancel Service');
insert into system.approle(code, display_value, status, description) values('RevertService', 'Revert Service', 'c', 'Revert previously Complete Service');
insert into system.approle(code, display_value, status, description) values('ApplnApprove', 'Approve Application', 'c', 'Approve Application');
insert into system.approle(code, display_value, status, description) values('ApplnReject', 'Reject Application', 'c', 'Land Office rejects an application');
insert into system.approle(code, display_value, status, description) values('ApplnValidate', 'Validate Application', 'c', 'User manually runs validation rules for application');
insert into system.approle(code, display_value, status, description) values('ApplnArchive', 'Archive Application', 'c', 'Paper Application File is stored in Land Office Archive');
insert into system.approle(code, display_value, status, description) values('BaunitSave', 'Create or Modify BA Unit', 'c', 'Create or Modify BA Unit (Property)');
insert into system.approle(code, display_value, status, description) values('BaunitCertificate', 'Generate and Print (BA Unit) Certificate', 'c', 'Generate and Print (BA Unit) Certificate');
insert into system.approle(code, display_value, status, description) values('BaunitSearch', 'Search BA Unit', 'c', 'Search BA Unit');
insert into system.approle(code, display_value, status, description) values('TransactionCommit', 'Approve (and Cancel) Transaction', 'c', 'Approve (and Cancel) Transaction');
insert into system.approle(code, display_value, status, description) values('ViewMap', 'View Cadastral Map', 'c', 'View Cadastral Map');
insert into system.approle(code, display_value, status, description) values('PrintMap', 'Print Map', 'c', 'Print Map');
insert into system.approle(code, display_value, status, description) values('ParcelSave', 'Create or modify (Cadastre) Parcel', 'c', 'Create or modify (Cadastre) Parcel');
insert into system.approle(code, display_value, status, description) values('PartySave', 'Create or modify Party', 'c', 'Create or modify Party');
insert into system.approle(code, display_value, status, description) values('SourceSave', 'Create or modify Source', 'c', 'Create or modify Source');
insert into system.approle(code, display_value, status, description) values('SourceSearch', 'Search Sources', 'c', 'Search sources');
insert into system.approle(code, display_value, status, description) values('SourcePrint', 'Print Sources', 'c', 'Print Source');
insert into system.approle(code, display_value, status, description) values('ReportGenerate', 'Generate and View Reports', 'c', 'Generate and View reports');
insert into system.approle(code, display_value, status, description) values('ArchiveApps', 'Archive applications', 'c', 'Archive applications');
insert into system.approle(code, display_value, status, description) values('ManageSecurity', 'Manage users, groups and roles', 'c', 'Manage users, groups and roles');
insert into system.approle(code, display_value, status, description) values('ManageRefdata', 'Manage reference data', 'c', 'Manage reference data');
insert into system.approle(code, display_value, status, description) values('ManageSettings', 'Manage system settings', 'c', 'Manage system settings');
insert into system.approle(code, display_value, status, description) values('ApplnEdit', 'Application Edit', 'c', 'Allows editing of Applications');
insert into system.approle(code, display_value, status, description) values('ManageBR', 'Manage business rules', 'c', 'Allows to manage business rules');
insert into system.approle(code, display_value, status, description) values('MapSheetSave', 'Manage office map sheets', 'c', 'Manage map sheets in the current office');
insert into system.approle(code, display_value, status, description) values('ParcelDetailsSave', 'Change parcel details', 'c', 'Change parcel details, except spatial data');
insert into system.approle(code, display_value, status, description) values('RHSave', 'Save rightholders', 'c', 'The same as party save role, but checks if party has any rights.');
insert into system.approle(code, display_value, status, description) values('MothManagement', 'Create and manage Moth', 'c', 'Allows to create and manage Moth and it''s pages');
insert into system.approle(code, display_value, status, description) values('RestrictionSearch', 'Search restrictions', 'c', 'Search restrictions');
insert into system.approle(code, display_value, status, description) values('PrintRestrLetter', 'Print restriction letter', 'c', 'Print restriction letter');
insert into system.approle(code, display_value, status, description) values('DoRegServices', 'Run and complete registration services', 'c', 'Allows to run and complete registration services');
insert into system.approle(code, display_value, status, description) values('DoCadastreServices', 'Run and complete cadastre services', 'c', 'Allows to run and complete cadastre services');
insert into system.approle(code, display_value, status, description) values('DoInfoServices', 'Run and complete information services', 'c', 'Allows to run and complete information services');



--Table system.appgroup ----
DROP TABLE IF EXISTS system.appgroup CASCADE;
CREATE TABLE system.appgroup(
    id varchar(40) NOT NULL,
    name varchar(300) NOT NULL,
    description varchar(500),

    -- Internal constraints
    
    CONSTRAINT appgroup_name_unique UNIQUE (name),
    CONSTRAINT appgroup_pkey PRIMARY KEY (id)
);

    
 -- Data for the table system.appgroup -- 
insert into system.appgroup(id, name, description) values('super-group-id', 'Super group', 'This is a group of users that has right in anything. It is used in developement. In production must be removed.');



--Table system.appuser_appgroup ----
DROP TABLE IF EXISTS system.appuser_appgroup CASCADE;
CREATE TABLE system.appuser_appgroup(
    appuser_id varchar(40) NOT NULL,
    appgroup_id varchar(40) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT appuser_appgroup_pkey PRIMARY KEY (appuser_id,appgroup_id)
);

    
 -- Data for the table system.appuser_appgroup -- 
insert into system.appuser_appgroup(appuser_id, appgroup_id) values('test-id', 'super-group-id');



--Table system.query ----
DROP TABLE IF EXISTS system.query CASCADE;
CREATE TABLE system.query(
    name varchar(100) NOT NULL,
    sql varchar(4000) NOT NULL,
    description varchar(1000),

    -- Internal constraints
    
    CONSTRAINT query_pkey PRIMARY KEY (name)
);

    
 -- Data for the table system.query -- 
insert into system.query(name, sql) values('SpatialResult.getParcels', 'select co.id, co.name_firstpart || ''/'' || co.name_lastpart as label,  st_asewkb(co.geom_polygon) as the_geom from cadastre.cadastre_object co where type_code= ''parcel'' and status_code= ''current'' and co.dataset_id = #{datasetId}');
insert into system.query(name, sql) values('SpatialResult.getParcelsPending', 'select co.id, co.name_firstpart || ''/'' || co.name_lastpart as label,  st_asewkb(co.geom_polygon) as the_geom,co.map_sheet_id,co.type_code  from cadastre.cadastre_object co  where type_code= ''parcel'' and status_code= ''pending'' union select co.id, co.name_firstpart || ''/'' || co.name_lastpart as label,  st_asewkb(co_t.geom_polygon) as the_geom,co.map_sheet_id,co.type_code  from cadastre.cadastre_object co inner join cadastre.cadastre_object_target co_t on co.id = co_t.cadastre_object_id and co_t.geom_polygon is not null where co_t.transaction_id in (select id from transaction.transaction where status_code not in (''approved'')) and co.dataset_id = #{datasetId}');
insert into system.query(name, sql) values('SpatialResult.getSurveyControls', 'select id, label, st_asewkb(geom) as the_geom from cadastre.survey_control  where ST_Intersects(geom, SetSRID(ST_MakeBox3D(ST_Point(#{minx}, #{miny}),ST_Point(#{maxx}, #{maxy})), #{srid}))');
insert into system.query(name, sql) values('SpatialResult.getRoads', 'select id, label, st_asewkb(geom) as the_geom from cadastre.road where ST_Intersects(geom, SetSRID(ST_MakeBox3D(ST_Point(#{minx}, #{miny}),ST_Point(#{maxx}, #{maxy})), #{srid}))');
insert into system.query(name, sql) values('SpatialResult.getPlaceNames', 'select id, label, st_asewkb(geom) as the_geom from cadastre.place_name where ST_Intersects(geom, SetSRID(ST_MakeBox3D(ST_Point(#{minx}, #{miny}),ST_Point(#{maxx}, #{maxy})), #{srid}))');
insert into system.query(name, sql) values('SpatialResult.getApplications', 'select id, nr as label, st_asewkb(location) as the_geom from application.application where ST_Intersects(location, SetSRID(ST_MakeBox3D(ST_Point(#{minx}, #{miny}),ST_Point(#{maxx}, #{maxy})), #{srid}))');
insert into system.query(name, sql) values('dynamic.informationtool.get_parcel', 'select co.id, co.name_firstpart || ''/'' || co.name_lastpart as parcel_nr, (select string_agg(ba.name_firstpart || ''/'' || ba.name_lastpart, '','') from administrative.ba_unit ba where ba.cadastre_object_id = co.id) as ba_units, co.official_area AS area_official_sqm, st_asewkb(co.geom_polygon) as the_geom from cadastre.cadastre_object co where type_code= ''parcel'' and status_code= ''current'' and ST_Intersects(co.geom_polygon, ST_SetSRID(ST_GeomFromWKB(#{wkb_geom}), #{srid}))');
insert into system.query(name, sql) values('dynamic.informationtool.get_parcel_pending', 'select co.id, co.name_firstpart || ''/'' || co.name_lastpart as parcel_nr, co.official_area AS area_official_sqm,   st_asewkb(co.geom_polygon) as the_geom from cadastre.cadastre_object co  where type_code= ''parcel'' and ((status_code= ''pending'' and ST_Intersects(co.geom_polygon, ST_SetSRID(ST_GeomFromWKB(#{wkb_geom}), #{srid})))   or (co.id in (select cadastre_object_id from cadastre.cadastre_object_target co_t inner join transaction.transaction t on co_t.transaction_id=t.id where ST_Intersects(co_t.geom_polygon, ST_SetSRID(ST_GeomFromWKB(#{wkb_geom}), #{srid})) and t.status_code not in (''approved''))))');
insert into system.query(name, sql) values('dynamic.informationtool.get_place_name', 'select id, label,  st_asewkb(geom) as the_geom from cadastre.place_name where ST_Intersects(geom, ST_SetSRID(ST_GeomFromWKB(#{wkb_geom}), #{srid}))');
insert into system.query(name, sql) values('dynamic.informationtool.get_road', 'select id, label,  st_asewkb(geom) as the_geom from cadastre.road where ST_Intersects(geom, ST_SetSRID(ST_GeomFromWKB(#{wkb_geom}), #{srid}))');
insert into system.query(name, sql) values('dynamic.informationtool.get_application', 'select id, nr,  st_asewkb(location) as the_geom from application.application where ST_Intersects(location, ST_SetSRID(ST_GeomFromWKB(#{wkb_geom}), #{srid}))');
insert into system.query(name, sql) values('dynamic.informationtool.get_survey_control', 'select id, label,  st_asewkb(geom) as the_geom from cadastre.survey_control where ST_Intersects(geom, ST_SetSRID(ST_GeomFromWKB(#{wkb_geom}), #{srid}))');
insert into system.query(name, sql) values('SpatialResult.getconstructions', 'select cid, id,constype, st_asewkb(geom_polygon) as the_geom from cadastre.construction where ST_Intersects(geom_polygon, SetSRID(ST_MakeBox3D(ST_Point(#{minx}, #{miny}),ST_Point(#{maxx}, #{maxy})), #{srid}))');
insert into system.query(name, sql) values('dynamic.informationtool.get_construction', 'select cid, id,constype,  st_asewkb(geom_polygon) as the_geom from cadastre.construction where ST_Intersects(geom_polygon, ST_SetSRID(ST_GeomFromWKB(#{wkb_geom}), #{srid}))');
insert into system.query(name, sql) values('SpatialResult.getsegments', 'select sid,id,bound_type,segno,shape_length, st_asewkb(the_geom) as the_geom from cadastre.segments where ST_Intersects(the_geom, SetSRID(ST_MakeBox3D(ST_Point(#{minx}, #{miny}),ST_Point(#{maxx}, #{maxy})), #{srid}))');
insert into system.query(name, sql) values('dynamic.informationtool.get_segment', 'select sid, id,bound_type,segno,shape_length,  st_asewkb(the_geom) as the_geom from cadastre.segments where ST_Intersects(the_geom, ST_SetSRID(ST_GeomFromWKB(#{wkb_geom}), #{srid}))');



--Table system.query_field ----
DROP TABLE IF EXISTS system.query_field CASCADE;
CREATE TABLE system.query_field(
    query_name varchar(100) NOT NULL,
    index_in_query integer NOT NULL,
    name varchar(100) NOT NULL,
    display_value varchar(200),

    -- Internal constraints
    
    CONSTRAINT query_field_display_value UNIQUE (query_name, display_value),
    CONSTRAINT query_field_name UNIQUE (query_name, name),
    CONSTRAINT query_field_pkey PRIMARY KEY (query_name,index_in_query)
);

    
 -- Data for the table system.query_field -- 
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_parcel', 1, 'parcel_nr', 'Parcel number::::ITALIANO');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_parcel', 2, 'ba_units', 'Properties::::ITALIANO');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_parcel', 3, 'area_official_sqm', 'Official area (m2)::::ITALIANO');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_parcel', 0, 'id');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_parcel', 4, 'the_geom');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_parcel_pending', 0, 'id');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_parcel_pending', 1, 'parcel_nr', 'Parcel number::::ITALIANO');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_parcel_pending', 2, 'area_official_sqm', 'Official area (m2)::::ITALIANO');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_parcel_pending', 3, 'the_geom');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_place_name', 0, 'id');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_place_name', 1, 'label', 'Name::::Nome');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_place_name', 2, 'the_geom');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_road', 0, 'id');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_road', 1, 'label', 'Name::::Nome');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_road', 2, 'the_geom');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_application', 0, 'id');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_application', 1, 'nr', 'Number::::Numero');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_application', 2, 'the_geom');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_survey_control', 0, 'id');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_survey_control', 1, 'label', 'Label::::ITALIANO');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_survey_control', 2, 'the_geom');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_construction', 0, 'cid', 'Const. ID::::Const.ID');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_construction', 1, 'id', 'Parcel ID::::Parcel ID');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_construction', 2, 'constype', 'Construction type::::Construction type');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_construction', 3, 'the_geom');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_segment', 0, 'sid', 'Seg ID::::Seg ID');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_segment', 1, 'id', 'Parcel ID::::Parcel ID');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_segment', 2, 'bound_type', 'Boundary type::::Boundary type');
insert into system.query_field(query_name, index_in_query, name, display_value) values('dynamic.informationtool.get_segment', 3, 'shape_length', 'Shape Length::::Shape Length');
insert into system.query_field(query_name, index_in_query, name) values('dynamic.informationtool.get_segment', 4, 'the_geom');



--Table cadastre.cadastre_object_node_target ----
DROP TABLE IF EXISTS cadastre.cadastre_object_node_target CASCADE;
CREATE TABLE cadastre.cadastre_object_node_target(
    transaction_id varchar(40) NOT NULL,
    node_id varchar(40) NOT NULL,
    geom GEOMETRY NOT NULL,
    CONSTRAINT enforce_dims_geom CHECK (st_ndims(geom) = 2),
    
            CONSTRAINT enforce_srid_geom CHECK (st_srid(geom) = 97261),
    CONSTRAINT enforce_geotype_geom CHECK (geometrytype(geom) = 'POINT'::text OR geom IS NULL),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT cadastre_object_node_target_pkey PRIMARY KEY (transaction_id,node_id)
);


CREATE INDEX cadastre_object_node_target_index_on_rowidentifier ON cadastre.cadastre_object_node_target (rowidentifier);
CREATE INDEX cadastre_object_node_target_index_on_geom ON cadastre.cadastre_object_node_target USING gist (geom);

    
DROP TRIGGER IF EXISTS __track_changes ON cadastre.cadastre_object_node_target CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON cadastre.cadastre_object_node_target FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table cadastre.cadastre_object_node_target_historic used for the history of data of table cadastre.cadastre_object_node_target ---
DROP TABLE IF EXISTS cadastre.cadastre_object_node_target_historic CASCADE;
CREATE TABLE cadastre.cadastre_object_node_target_historic
(
    transaction_id varchar(40),
    node_id varchar(40),
    geom GEOMETRY,
    CONSTRAINT enforce_dims_geom CHECK (st_ndims(geom) = 2),
    
            CONSTRAINT enforce_srid_geom CHECK (st_srid(geom) = 97261),
    CONSTRAINT enforce_geotype_geom CHECK (geometrytype(geom) = 'POINT'::text OR geom IS NULL),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX cadastre_object_node_target_historic_index_on_rowidentifier ON cadastre.cadastre_object_node_target_historic (rowidentifier);
CREATE INDEX cadastre_object_node_target_historic_index_on_geom ON cadastre.cadastre_object_node_target_historic USING gist (geom);


DROP TRIGGER IF EXISTS __track_history ON cadastre.cadastre_object_node_target CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON cadastre.cadastre_object_node_target FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table administrative.ba_unit_target ----
DROP TABLE IF EXISTS administrative.ba_unit_target CASCADE;
CREATE TABLE administrative.ba_unit_target(
    ba_unit_id varchar(40) NOT NULL,
    transaction_id varchar(40) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT ba_unit_target_pkey PRIMARY KEY (ba_unit_id,transaction_id)
);


CREATE INDEX ba_unit_target_index_on_rowidentifier ON administrative.ba_unit_target (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON administrative.ba_unit_target CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON administrative.ba_unit_target FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table administrative.ba_unit_target_historic used for the history of data of table administrative.ba_unit_target ---
DROP TABLE IF EXISTS administrative.ba_unit_target_historic CASCADE;
CREATE TABLE administrative.ba_unit_target_historic
(
    ba_unit_id varchar(40),
    transaction_id varchar(40),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX ba_unit_target_historic_index_on_rowidentifier ON administrative.ba_unit_target_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON administrative.ba_unit_target CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON administrative.ba_unit_target FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table cadastre.verticalParcel ----
DROP TABLE IF EXISTS cadastre.verticalParcel CASCADE;
CREATE TABLE cadastre.verticalParcel(
    vid integer NOT NULL,
    geom_polygon GEOMETRY,
    CONSTRAINT enforce_dims_geom_polygon CHECK (st_ndims(geom_polygon) = 2),
    
            CONSTRAINT enforce_srid_geom_polygon CHECK (st_srid(geom_polygon) = 97261),
    CONSTRAINT enforce_geotype_geom_polygon CHECK (geometrytype(geom_polygon) = 'POLYGON'::text OR geom_polygon IS NULL),
    id varchar(40) NOT NULL,
    height numeric(19, 3),
    ownerId integer,
    area numeric(29, 3),

    -- Internal constraints
    
    CONSTRAINT verticalParcel_pkey PRIMARY KEY (vid,id)
);


CREATE INDEX verticalParcel_index_on_geom_polygon ON cadastre.verticalParcel USING gist (geom_polygon);

    
--Table cadastre.construction ----
DROP TABLE IF EXISTS cadastre.construction CASCADE;
CREATE TABLE cadastre.construction(
    cid integer NOT NULL,
    geom_polygon GEOMETRY,
    CONSTRAINT enforce_dims_geom_polygon CHECK (st_ndims(geom_polygon) = 2),
    
            CONSTRAINT enforce_srid_geom_polygon CHECK (st_srid(geom_polygon) = 97261),
    CONSTRAINT enforce_geotype_geom_polygon CHECK (geometrytype(geom_polygon) = 'POLYGON'::text OR geom_polygon IS NULL),
    id varchar(40) NOT NULL,
    constype integer NOT NULL,
    area numeric(29, 3),

    -- Internal constraints
    
    CONSTRAINT construction_pkey PRIMARY KEY (cid,id)
);


CREATE INDEX construction_index_on_geom_polygon ON cadastre.construction USING gist (geom_polygon);

    
--Table cadastre.boundary_type ----
DROP TABLE IF EXISTS cadastre.boundary_type CASCADE;
CREATE TABLE cadastre.boundary_type(
    code integer NOT NULL,
    description varchar(255),

    -- Internal constraints
    
    CONSTRAINT boundary_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.boundary_type -- 
insert into cadastre.boundary_type(code, description) values(0, 'None::::None');
insert into cadastre.boundary_type(code, description) values(10, 'Building Foot Print::::Building Foot Print');
insert into cadastre.boundary_type(code, description) values(20, 'Wall::::Wall');
insert into cadastre.boundary_type(code, description) values(25, 'Shared Wall::::Shared Wall');
insert into cadastre.boundary_type(code, description) values(30, 'Fence::::Fence');
insert into cadastre.boundary_type(code, description) values(35, 'Shared Fence::::Shared Fence');
insert into cadastre.boundary_type(code, description) values(40, 'Gate::::Gate');
insert into cadastre.boundary_type(code, description) values(50, 'Line Canal::::Line Canal');
insert into cadastre.boundary_type(code, description) values(52, 'Line Canal and Wall::::Line Canal and Wall');
insert into cadastre.boundary_type(code, description) values(54, 'Line Canal and Fence::::Line Canal and Fence');
insert into cadastre.boundary_type(code, description) values(58, 'Line Canal and Gate::::Line Canal and Gate');



--Table cadastre.construction_type ----
DROP TABLE IF EXISTS cadastre.construction_type CASCADE;
CREATE TABLE cadastre.construction_type(
    code integer NOT NULL,
    description varchar(255),

    -- Internal constraints
    
    CONSTRAINT construction_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.construction_type -- 
insert into cadastre.construction_type(code, description) values(0, 'Permanent Building::::Permanent Building');
insert into cadastre.construction_type(code, description) values(10, 'Temporary Building::::Temporary Building');
insert into cadastre.construction_type(code, description) values(20, 'Damaged Building::::Damaged Building');
insert into cadastre.construction_type(code, description) values(30, 'Wall::::Wall');
insert into cadastre.construction_type(code, description) values(40, 'Pond::::Pond');
insert into cadastre.construction_type(code, description) values(50, 'Gate/Entrance::::Gate/Entrance');
insert into cadastre.construction_type(code, description) values(60, 'Temple::::Temple');
insert into cadastre.construction_type(code, description) values(150, 'Stupa::::Stupa');



--Table cadastre.adminstrative_boundary_type ----
DROP TABLE IF EXISTS cadastre.adminstrative_boundary_type CASCADE;
CREATE TABLE cadastre.adminstrative_boundary_type(
    code integer NOT NULL,
    description varchar(255),

    -- Internal constraints
    
    CONSTRAINT adminstrative_boundary_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.adminstrative_boundary_type -- 
insert into cadastre.adminstrative_boundary_type(code, description) values(0, 'None::::None');
insert into cadastre.adminstrative_boundary_type(code, description) values(10, 'Ward::::Ward');
insert into cadastre.adminstrative_boundary_type(code, description) values(20, 'VDC/Municipality::::VDC/Municipality');
insert into cadastre.adminstrative_boundary_type(code, description) values(30, 'District::::District');
insert into cadastre.adminstrative_boundary_type(code, description) values(40, 'Zone::::Zone');
insert into cadastre.adminstrative_boundary_type(code, description) values(50, 'National::::National');



--Table cadastre.map_boundary_type ----
DROP TABLE IF EXISTS cadastre.map_boundary_type CASCADE;
CREATE TABLE cadastre.map_boundary_type(
    code integer NOT NULL,
    description varchar(255),

    -- Internal constraints
    
    CONSTRAINT map_boundary_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.map_boundary_type -- 
insert into cadastre.map_boundary_type(code, description) values(0, 'None::::None');
insert into cadastre.map_boundary_type(code, description) values(10, 'Grid Sheet::::Grid Sheet');
insert into cadastre.map_boundary_type(code, description) values(20, 'Free Sheet::::Free Sheet');



--Table cadastre.segments ----
DROP TABLE IF EXISTS cadastre.segments CASCADE;
CREATE TABLE cadastre.segments(
    sid integer NOT NULL,
    segno integer,
    the_geom GEOMETRY,
    CONSTRAINT enforce_dims_the_geom CHECK (st_ndims(the_geom) = 2),
    
            CONSTRAINT enforce_srid_the_geom CHECK (st_srid(the_geom) = 97261),
    CONSTRAINT enforce_geotype_the_geom CHECK (geometrytype(the_geom) = 'LINESTRING'::text OR the_geom IS NULL),
    bound_type integer NOT NULL,
    id varchar(40) NOT NULL,
    mbound_type integer NOT NULL,
    abound_type integer NOT NULL,
    shape_length numeric(19, 3),

    -- Internal constraints
    
    CONSTRAINT segments_pkey PRIMARY KEY (sid,id)
);


CREATE INDEX segments_index_on_the_geom ON cadastre.segments USING gist (the_geom);

    
--Table system.np_calendar ----
DROP TABLE IF EXISTS system.np_calendar CASCADE;
CREATE TABLE system.np_calendar(
    nep_year integer NOT NULL,
    nep_month integer NOT NULL,
    dayss integer,

    -- Internal constraints
    
    CONSTRAINT np_calendar_pkey PRIMARY KEY (nep_year,nep_month)
);

    
 -- Data for the table system.np_calendar -- 
insert into system.np_calendar(nep_year, nep_month, dayss) values(2064, 1, 31);
insert into system.np_calendar(nep_year, nep_month, dayss) values(2065, 1, 31);
insert into system.np_calendar(nep_year, nep_month, dayss) values(2066, 1, 31);
insert into system.np_calendar(nep_year, nep_month, dayss) values(2067, 1, 31);
insert into system.np_calendar(nep_year, nep_month, dayss) values(2068, 1, 31);
insert into system.np_calendar(nep_year, nep_month, dayss) values(2069, 1, 31);
insert into system.np_calendar(nep_year, nep_month, dayss) values(2070, 1, 31);



--Table system.alpha_code ----
DROP TABLE IF EXISTS system.alpha_code CASCADE;
CREATE TABLE system.alpha_code(
    code varchar(20) NOT NULL,
    alpha_char varchar(10),

    -- Internal constraints
    
    CONSTRAINT alpha_code_pkey PRIMARY KEY (code)
);

    
--Table system.financial_year ----
DROP TABLE IF EXISTS system.financial_year CASCADE;
CREATE TABLE system.financial_year(
    code varchar(20) NOT NULL,
    display_value varchar(250),
    status char(1) NOT NULL DEFAULT ('c'),
    current bool NOT NULL DEFAULT ('f'),
    start_date date NOT NULL,
    end_date date NOT NULL,
    description varchar(255),

    -- Internal constraints
    
    CONSTRAINT financial_year_pkey PRIMARY KEY (code)
);

    
 -- Data for the table system.financial_year -- 
insert into system.financial_year(code, display_value, status, current, start_date, end_date) values('68', '6970', 'c', true, '2012-07-16', '2013-07-18');



--Table system.office ----
DROP TABLE IF EXISTS system.office CASCADE;
CREATE TABLE system.office(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    district_code varchar(20) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('c'),

    -- Internal constraints
    
    CONSTRAINT office_pkey PRIMARY KEY (code)
);

    
 -- Data for the table system.office -- 
insert into system.office(code, display_value, district_code, status) values('101', 'मालपोत कायार्लय काठमाडौं कलंकी', '27', 'c');
insert into system.office(code, display_value, district_code, status) values('102', 'मालपोत कायार्लय काठमाडौं डिल्लीबजार', '27', 'c');
insert into system.office(code, display_value, district_code, status) values('104', 'मालपोत कायार्लय चावहिल', '27', 'c');



--Table address.district ----
DROP TABLE IF EXISTS address.district CASCADE;
CREATE TABLE address.district(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    zone_code integer,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('c'),
    region_code integer,

    -- Internal constraints
    
    CONSTRAINT district_pkey PRIMARY KEY (code)
);

    
 -- Data for the table address.district -- 
insert into address.district(code, display_value, zone_code, status) values('25', 'Lalitpur', 7, 'c');
insert into address.district(code, display_value, zone_code, status) values('27', 'Bhaktpur', 7, 'c');



--Table cadastre.map_sheet ----
DROP TABLE IF EXISTS cadastre.map_sheet CASCADE;
CREATE TABLE cadastre.map_sheet(
    id varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    map_number varchar(50) NOT NULL,
    sheet_type integer,
    ward_no varchar(10),
    office_code varchar(20) NOT NULL,
    srid integer NOT NULL,

    -- Internal constraints
    
    CONSTRAINT map_sheet_unique_map_number_office_code UNIQUE (map_number, office_code),
    CONSTRAINT map_sheet_pkey PRIMARY KEY (id)
);

    
 -- Data for the table cadastre.map_sheet -- 
insert into cadastre.map_sheet(id, map_number, sheet_type, office_code, srid) values('1', '010', 0, '101', 97260);



--Table address.vdc ----
DROP TABLE IF EXISTS address.vdc CASCADE;
CREATE TABLE address.vdc(
    code varchar(20) NOT NULL,
    display_value varchar(50) NOT NULL,
    district_code varchar(20) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('c'),

    -- Internal constraints
    
    CONSTRAINT vdc_pkey PRIMARY KEY (code)
);

    
 -- Data for the table address.vdc -- 
insert into address.vdc(code, display_value, district_code, description, status) values('43055', 'Singana', '25', 'Test VDC', 'c');
insert into address.vdc(code, display_value, district_code, description, status) values('27009', 'Mulpani', '27', 'Mulpani', 'c');



--Table system.department ----
DROP TABLE IF EXISTS system.department CASCADE;
CREATE TABLE system.department(
    code varchar(20) NOT NULL,
    office_code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(500),
    status char(1) NOT NULL DEFAULT ('c'),

    -- Internal constraints
    
    CONSTRAINT department_unique_department_name UNIQUE (office_code, display_value),
    CONSTRAINT department_pkey PRIMARY KEY (code)
);

    
 -- Data for the table system.department -- 
insert into system.department(code, office_code, display_value, status) values('Lalitpur-001', '101', 'Section-001, Lalitpur LMO', 'c');



--Table administrative.loc ----
DROP TABLE IF EXISTS administrative.loc CASCADE;
CREATE TABLE administrative.loc(
    id varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    moth_id varchar(40) NOT NULL,
    pana_no varchar(15),
    tmp_pana_no varchar(15),
    office_code varchar(20) NOT NULL,
    creation_date date DEFAULT (now()),
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT loc_unique_page_number UNIQUE (moth_id, pana_no),
    CONSTRAINT loc_unique_tmp_page_number UNIQUE (moth_id, tmp_pana_no),
    CONSTRAINT loc_pkey PRIMARY KEY (id)
);


CREATE INDEX loc_index_on_rowidentifier ON administrative.loc (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON administrative.loc CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON administrative.loc FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table administrative.loc_historic used for the history of data of table administrative.loc ---
DROP TABLE IF EXISTS administrative.loc_historic CASCADE;
CREATE TABLE administrative.loc_historic
(
    id varchar(40),
    moth_id varchar(40),
    pana_no varchar(15),
    tmp_pana_no varchar(15),
    office_code varchar(20),
    creation_date date,
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX loc_historic_index_on_rowidentifier ON administrative.loc_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON administrative.loc CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON administrative.loc FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table administrative.moth ----
DROP TABLE IF EXISTS administrative.moth CASCADE;
CREATE TABLE administrative.moth(
    id varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    mothluj_no varchar(15) NOT NULL,
    vdc_code varchar(20) NOT NULL,
    moth_luj varchar(2) NOT NULL,
    office_code varchar(20) NOT NULL,
    ward_no varchar(20),
    fy_code varchar(10) NOT NULL,
    rowidentifier varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    rowversion integer NOT NULL DEFAULT (0),
    change_action char(1) NOT NULL DEFAULT ('i'),
    change_user varchar(50),
    change_time timestamp NOT NULL DEFAULT (now()),

    -- Internal constraints
    
    CONSTRAINT moth_unique_moth_no_office UNIQUE (mothluj_no, office_code, moth_luj, vdc_code, fy_code),
    CONSTRAINT moth_pkey PRIMARY KEY (id)
);


CREATE INDEX moth_index_on_rowidentifier ON administrative.moth (rowidentifier);

    
DROP TRIGGER IF EXISTS __track_changes ON administrative.moth CASCADE;
CREATE TRIGGER __track_changes BEFORE UPDATE OR INSERT
   ON administrative.moth FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_changes();
    

----Table administrative.moth_historic used for the history of data of table administrative.moth ---
DROP TABLE IF EXISTS administrative.moth_historic CASCADE;
CREATE TABLE administrative.moth_historic
(
    id varchar(40),
    mothluj_no varchar(15),
    vdc_code varchar(20),
    moth_luj varchar(2),
    office_code varchar(20),
    ward_no varchar(20),
    fy_code varchar(10),
    rowidentifier varchar(40),
    rowversion integer,
    change_action char(1),
    change_user varchar(50),
    change_time timestamp,
    change_time_valid_until TIMESTAMP NOT NULL default NOW()
);

CREATE INDEX moth_historic_index_on_rowidentifier ON administrative.moth_historic (rowidentifier);


DROP TRIGGER IF EXISTS __track_history ON administrative.moth CASCADE;
CREATE TRIGGER __track_history AFTER UPDATE OR DELETE
   ON administrative.moth FOR EACH ROW
   EXECUTE PROCEDURE f_for_trg_track_history();
    
--Table administrative.restriction_reason ----
DROP TABLE IF EXISTS administrative.restriction_reason CASCADE;
CREATE TABLE administrative.restriction_reason(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT restriction_reason_pkey PRIMARY KEY (code)
);

    
 -- Data for the table administrative.restriction_reason -- 
insert into administrative.restriction_reason(code, display_value, status) values('1', 'Legal Case::::मुद्दा मामिला', 'c');
insert into administrative.restriction_reason(code, display_value, status) values('2', 'Acquisition::::अधिकरण', 'c');
insert into administrative.restriction_reason(code, display_value, status) values('3', 'Land ceiling::::हदबन्दि', 'c');
insert into administrative.restriction_reason(code, display_value, status) values('4', 'Financial transaction::::आर्थिक कारोबार', 'c');
insert into administrative.restriction_reason(code, display_value, status) values('10', 'Advance Receive::::बैना बुझिलिएको', 'c');
insert into administrative.restriction_reason(code, display_value, status) values('11', 'Litigation::::खिचोला (झमेला)', 'c');
insert into administrative.restriction_reason(code, display_value, status) values('12', 'हालैको बकस पत्र ', 'c');
insert into administrative.restriction_reason(code, display_value, status) values('13', 'नखुलेको', 'c');
insert into administrative.restriction_reason(code, display_value, status) values('14', 'आयोग रोक्का', 'c');
insert into administrative.restriction_reason(code, display_value, status) values('5', 'Bhog bandagi::::भोग बन्धकी', 'c');
insert into administrative.restriction_reason(code, display_value, status) values('6', 'Dristi Bandhaki::::दृष्टि बन्धकी', 'c');
insert into administrative.restriction_reason(code, display_value, status) values('7', 'Lakha Bandhaki::::लख बन्धिकी', 'c');
insert into administrative.restriction_reason(code, display_value, status) values('8', 'Will::::शेष पछिको बकस पत्र', 'c');
insert into administrative.restriction_reason(code, display_value, status) values('9', 'Contract Paper::::करार नामा', 'c');



--Table administrative.restriction_release_reason ----
DROP TABLE IF EXISTS administrative.restriction_release_reason CASCADE;
CREATE TABLE administrative.restriction_release_reason(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT restriction_release_reason_pkey PRIMARY KEY (code)
);

    
 -- Data for the table administrative.restriction_release_reason -- 
insert into administrative.restriction_release_reason(code, display_value, status) values('1', 'By Letter::::फुकुवा पत्रानुसार', 'c');
insert into administrative.restriction_release_reason(code, display_value, status) values('2', 'By Office::::कार्यालयको निर्णयानुसार', 'c');
insert into administrative.restriction_release_reason(code, display_value, status) values('3', 'By Court Order::::अदालतको आदेशानुसार', 'c');



--Table administrative.restriction_office ----
DROP TABLE IF EXISTS administrative.restriction_office CASCADE;
CREATE TABLE administrative.restriction_office(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT restriction_office_pkey PRIMARY KEY (code)
);

    
 -- Data for the table administrative.restriction_office -- 
insert into administrative.restriction_office(code, display_value, status) values('1', 'Household and Development', 'c');
insert into administrative.restriction_office(code, display_value, status) values('2', 'Development Credit Bank', 'c');
insert into administrative.restriction_office(code, display_value, status) values('3', 'Ramesh Kumar Sainju', 'c');



--Table administrative.owner_type ----
DROP TABLE IF EXISTS administrative.owner_type CASCADE;
CREATE TABLE administrative.owner_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT owner_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table administrative.owner_type -- 
insert into administrative.owner_type(code, display_value, status) values('3401', 'Raikar::::रैकर निजि', 'c');
insert into administrative.owner_type(code, display_value, status) values('3402', 'Private Guthi::::निजी गुठी', 'c');
insert into administrative.owner_type(code, display_value, status) values('3403', 'Govt. Guth::::गठी. अधिनस्त', 'c');
insert into administrative.owner_type(code, display_value, status) values('3404', 'Govt. Guthi Tai::::गुठी तैनाथी', 'c');
insert into administrative.owner_type(code, display_value, status) values('3405', 'Govt. Guthi Nam::::गुठी नंवरी', 'c');
insert into administrative.owner_type(code, display_value, status) values('3406', 'Govt. Guthi Rai::::राज गुठी रैतान नंवरी', 'c');
insert into administrative.owner_type(code, display_value, status) values('3407', 'Govt.::::सरकारी', 'c');
insert into administrative.owner_type(code, display_value, status) values('3408', 'Public::::सावर्जनीक', 'c');
insert into administrative.owner_type(code, display_value, status) values('3409', 'Aailani::::एैलानी', 'c');
insert into administrative.owner_type(code, display_value, status) values('3410', 'UnClaimed::::पतिर्', 'c');
insert into administrative.owner_type(code, display_value, status) values('3411', 'Govt. Amanati::::स. अमानती', 'c');
insert into administrative.owner_type(code, display_value, status) values('3412', 'Others::::अन्य', 'c');
insert into administrative.owner_type(code, display_value, status) values('3413', 'road::::बाटो प्रयोजन', 'c');
insert into administrative.owner_type(code, display_value, status) values('3414', '.', 'x');
insert into administrative.owner_type(code, display_value, status) values('3415', 'सहकारी', 'c');
insert into administrative.owner_type(code, display_value, status) values('3416', 'स्थानिय निकाय', 'c');



--Table administrative.ownership_type ----
DROP TABLE IF EXISTS administrative.ownership_type CASCADE;
CREATE TABLE administrative.ownership_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT ownership_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table administrative.ownership_type -- 
insert into administrative.ownership_type(code, display_value, description, status) values('3001', 'Single::::एकलौटी', 'Single', 'c');
insert into administrative.ownership_type(code, display_value, description, status) values('3002', 'Joint::::संयुक्त', 'Joint', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3003', 'पू. कोठा', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3004', 'प. कोठा', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3005', 'खण्डे हक', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3006', 'वगर् मिटर', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3007', 'उ. कोठा', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3008', 'द. कोठा', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3009', 'Blank::::बाटो (करिडोर)', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3010', 'कौसी', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3011', 'अन्य', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3012', 'एकलौटी', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3013', 'तल्ला', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3014', 'कोठा', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3015', 'मोहीलागेको', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3016', 'संगोल', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3017', 'एकलौटी', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3018', 'साझा', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3019', 'सबै', 'c');
insert into administrative.ownership_type(code, display_value, status) values('3020', 'बराबर', 'c');



--Table administrative.discount_type ----
DROP TABLE IF EXISTS administrative.discount_type CASCADE;
CREATE TABLE administrative.discount_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('c'),

    -- Internal constraints
    
    CONSTRAINT discount_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT discount_type_pkey PRIMARY KEY (code)
);

    
--Table cadastre.land_type ----
DROP TABLE IF EXISTS cadastre.land_type CASCADE;
CREATE TABLE cadastre.land_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT land_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.land_type -- 
insert into cadastre.land_type(code, display_value, status) values('1201', 'Dhanahar::::खेत', 'c');
insert into cadastre.land_type(code, display_value, status) values('1202', 'Bhir::::वारी', 'c');
insert into cadastre.land_type(code, display_value, status) values('1203', 'LowLand::::शहरी', 'c');
insert into cadastre.land_type(code, display_value, status) values('1204', 'UpLand::::चौर', 'c');
insert into cadastre.land_type(code, display_value, status) values('1205', 'UpLand::::बाटो', 'c');
insert into cadastre.land_type(code, display_value, status) values('1206', 'विकसीत घडेरी', 'c');



--Table cadastre.land_class ----
DROP TABLE IF EXISTS cadastre.land_class CASCADE;
CREATE TABLE cadastre.land_class(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT land_class_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.land_class -- 
insert into cadastre.land_class(code, display_value, status) values('1601', 'Abbal::::अब्बल', 'c');
insert into cadastre.land_class(code, display_value, status) values('1602', 'Doyam::::दोयम', 'c');
insert into cadastre.land_class(code, display_value, status) values('1603', 'Shim::::सीम', 'c');
insert into cadastre.land_class(code, display_value, status) values('1604', 'Chahar::::चाहार', 'c');
insert into cadastre.land_class(code, display_value, status) values('1605', 'Panchaun::::पांचौ', 'c');
insert into cadastre.land_class(code, display_value, status) values('1606', 'Municipality A::::क', 'c');
insert into cadastre.land_class(code, display_value, status) values('1607', 'Municipality B::::ख', 'c');
insert into cadastre.land_class(code, display_value, status) values('1608', 'Municipality C::::ग', 'c');
insert into cadastre.land_class(code, display_value, status) values('1609', 'Municipality D::::घ', 'c');
insert into cadastre.land_class(code, display_value, status) values('1610', 'Municipality E::::ङ', 'c');
insert into cadastre.land_class(code, display_value, status) values('1611', 'Municipality F::::च', 'c');
insert into cadastre.land_class(code, display_value, status) values('1612', 'Non Classified::::अवगिर्कृत', 'c');
insert into cadastre.land_class(code, display_value, status) values('1613', 'Others::::अन्य', 'c');



--Table cadastre.land_use ----
DROP TABLE IF EXISTS cadastre.land_use CASCADE;
CREATE TABLE cadastre.land_use(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT land_use_pkey PRIMARY KEY (code)
);

    
 -- Data for the table cadastre.land_use -- 
insert into cadastre.land_use(code, display_value, status) values('1401', 'Cutivated::::आवादी', 'c');
insert into cadastre.land_use(code, display_value, status) values('1402', 'Cultivatable::::आवाद लायक', 'c');
insert into cadastre.land_use(code, display_value, status) values('1403', 'Barren::::आवाद वेलायक', 'c');
insert into cadastre.land_use(code, display_value, status) values('1404', 'Dewlling Land::::घडेरी', 'c');
insert into cadastre.land_use(code, display_value, status) values('1405', 'Govt. Land::::ृऐलानी', 'c');
insert into cadastre.land_use(code, display_value, status) values('1406', 'Riverside::::घर', 'c');
insert into cadastre.land_use(code, display_value, status) values('1407', 'Building & Land::::घर जग्गा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1408', 'Play Ground::::जग्गा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1409', 'River::::घर पाताल', 'c');
insert into cadastre.land_use(code, display_value, status) values('1410', 'Pond::::पोखरी', 'c');
insert into cadastre.land_use(code, display_value, status) values('1411', 'Temple::::मंदीर', 'c');
insert into cadastre.land_use(code, display_value, status) values('1412', 'सागल', 'c');
insert into cadastre.land_use(code, display_value, status) values('1413', 'चोक', 'c');
insert into cadastre.land_use(code, display_value, status) values('1414', 'Forest::::वन', 'c');
insert into cadastre.land_use(code, display_value, status) values('1415', 'Garden::::वगैचा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1416', 'पतिर्', 'c');
insert into cadastre.land_use(code, display_value, status) values('1417', 'Road::::सडक', 'c');
insert into cadastre.land_use(code, display_value, status) values('1418', 'Canal::::नहर कुलेसा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1419', 'वनवुटयान', 'c');
insert into cadastre.land_use(code, display_value, status) values('1420', 'पानी पधेरो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1421', 'बाझो, पतिर्', 'c');
insert into cadastre.land_use(code, display_value, status) values('1422', 'नदी उकास', 'c');
insert into cadastre.land_use(code, display_value, status) values('1423', 'Private Forest::::नीजि वन', 'c');
insert into cadastre.land_use(code, display_value, status) values('1424', 'Others::::अन्य', 'c');
insert into cadastre.land_use(code, display_value, status) values('1425', 'Tea Garden::::्चिया वारी', 'c');
insert into cadastre.land_use(code, display_value, status) values('1426', 'Cardamom Farm::::अलैची खेती', 'c');
insert into cadastre.land_use(code, display_value, status) values('1427', 'Grave Land::::चिहान घाट', 'c');
insert into cadastre.land_use(code, display_value, status) values('1428', 'पाटी पौवा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1429', 'खोलो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1430', 'बगर', 'c');
insert into cadastre.land_use(code, display_value, status) values('1431', 'चौर', 'c');
insert into cadastre.land_use(code, display_value, status) values('1432', 'Pasture Land::::गौचर', 'c');
insert into cadastre.land_use(code, display_value, status) values('1433', 'Government::::सरकारी', 'c');
insert into cadastre.land_use(code, display_value, status) values('1434', 'पखार्ल', 'c');
insert into cadastre.land_use(code, display_value, status) values('1435', 'बाटो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1436', 'खर', 'c');
insert into cadastre.land_use(code, display_value, status) values('1437', 'बा¤स', 'c');
insert into cadastre.land_use(code, display_value, status) values('1438', 'निगालो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1439', 'चौतारी', 'c');
insert into cadastre.land_use(code, display_value, status) values('1440', 'स्कूल', 'c');
insert into cadastre.land_use(code, display_value, status) values('1441', 'नदी', 'c');
insert into cadastre.land_use(code, display_value, status) values('1442', 'सावर्जनीक', 'c');
insert into cadastre.land_use(code, display_value, status) values('1443', 'गोरेटो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1444', 'देवस्थान', 'c');
insert into cadastre.land_use(code, display_value, status) values('1445', 'धारा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1446', 'टहरा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1447', 'कुवा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1448', 'कुलेसो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1449', 'कुलो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1450', 'उतिस वुटेन', 'c');
insert into cadastre.land_use(code, display_value, status) values('1451', 'बास', 'c');
insert into cadastre.land_use(code, display_value, status) values('1452', 'भीर प्रति', 'c');
insert into cadastre.land_use(code, display_value, status) values('1453', 'बुटेन', 'c');
insert into cadastre.land_use(code, display_value, status) values('1454', 'जंगल', 'c');
insert into cadastre.land_use(code, display_value, status) values('1455', 'सल्लाधारी', 'c');
insert into cadastre.land_use(code, display_value, status) values('1456', 'ढुéा/ढुéेन', 'c');
insert into cadastre.land_use(code, display_value, status) values('1457', 'प्र. वेलायक', 'c');
insert into cadastre.land_use(code, display_value, status) values('1458', 'आवादी वे.प्र.', 'c');
insert into cadastre.land_use(code, display_value, status) values('1459', 'चिलाउने', 'c');
insert into cadastre.land_use(code, display_value, status) values('1460', 'राजबन्दी बगैचा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1461', 'निगालो वांस', 'c');
insert into cadastre.land_use(code, display_value, status) values('1462', 'आवादी ला.प्र.', 'c');
insert into cadastre.land_use(code, display_value, status) values('1463', '.', 'c');
insert into cadastre.land_use(code, display_value, status) values('1464', 'ढुéे धारा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1465', 'साली नदी', 'c');
insert into cadastre.land_use(code, display_value, status) values('1466', 'चौतारा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1467', 'राजकुलो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1468', 'साझा चोक', 'c');
insert into cadastre.land_use(code, display_value, status) values('1469', 'इनार', 'c');
insert into cadastre.land_use(code, display_value, status) values('1470', 'गोरेटो कुलो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1471', 'जंगल बुटेन', 'c');
insert into cadastre.land_use(code, display_value, status) values('1472', 'झाडी', 'c');
insert into cadastre.land_use(code, display_value, status) values('1473', 'प्रति वगर', 'c');
insert into cadastre.land_use(code, display_value, status) values('1474', 'नदी', 'c');
insert into cadastre.land_use(code, display_value, status) values('1475', 'खोला कुलो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1476', 'कुलो घट्ट', 'c');
insert into cadastre.land_use(code, display_value, status) values('1477', 'सानु खहर', 'c');
insert into cadastre.land_use(code, display_value, status) values('1478', 'ठूलो खहर', 'c');
insert into cadastre.land_use(code, display_value, status) values('1479', 'भीर जंगल', 'c');
insert into cadastre.land_use(code, display_value, status) values('1480', 'खोल्सो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1481', 'पहीरो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1482', 'प्र.बूटेन', 'c');
insert into cadastre.land_use(code, display_value, status) values('1483', 'गौरण', 'c');
insert into cadastre.land_use(code, display_value, status) values('1484', 'खो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1485', 'वू.भिर', 'c');
insert into cadastre.land_use(code, display_value, status) values('1486', 'प्र.सडक', 'c');
insert into cadastre.land_use(code, display_value, status) values('1487', 'ढूगो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1488', 'पो', 'c');
insert into cadastre.land_use(code, display_value, status) values('1489', 'माहा¤देव खोला', 'c');
insert into cadastre.land_use(code, display_value, status) values('1490', 'प्रतिर् ढूéा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1491', 'गूम्वा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1492', 'ढूéा', 'c');
insert into cadastre.land_use(code, display_value, status) values('1493', 'पंञ्चायत घर चोक स्कूल', 'c');
insert into cadastre.land_use(code, display_value, status) values('1494', 'टावर', 'c');
insert into cadastre.land_use(code, display_value, status) values('1495', 'भिर', 'c');
insert into cadastre.land_use(code, display_value, status) values('1496', 'चमेर', 'c');
insert into cadastre.land_use(code, display_value, status) values('1497', 'चौकी', 'c');
insert into cadastre.land_use(code, display_value, status) values('1498', 'ढिस्को', 'c');
insert into cadastre.land_use(code, display_value, status) values('1499', 'प्र. भिर', 'c');



--Table party.father_type ----
DROP TABLE IF EXISTS party.father_type CASCADE;
CREATE TABLE party.father_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) DEFAULT ('c'),

    -- Internal constraints
    
    CONSTRAINT father_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT father_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table party.father_type -- 
insert into party.father_type(code, display_value, status) values('3601', 'Father::::बाबु', 'c');
insert into party.father_type(code, display_value, status) values('3602', 'Husband::::पति', 'c');
insert into party.father_type(code, display_value, status) values('3603', 'Grand Father::::बाजे', 'c');
insert into party.father_type(code, display_value, status) values('3604', 'Father in Law::::ससुरा', 'c');
insert into party.father_type(code, display_value, status) values('3605', 'बाबु बाजे::::बाबु  पति', 'c');
insert into party.father_type(code, display_value, status) values('3606', 'पिता ससुरा::::पिता ससुरा', 'c');



--Table party.id_office_type ----
DROP TABLE IF EXISTS party.id_office_type CASCADE;
CREATE TABLE party.id_office_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    status char(1) NOT NULL DEFAULT ('t'),
    description varchar(555),

    -- Internal constraints
    
    CONSTRAINT id_office_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT id_office_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table party.id_office_type -- 
insert into party.id_office_type(code, display_value, status) values('1', 'District Admin. Office::::जिल्ला प्रशासन कायर्ालय', 'c');
insert into party.id_office_type(code, display_value, status) values('10', 'Magistrate Office::::मजिष्ट्रेटको कायर्ालय', 'c');
insert into party.id_office_type(code, display_value, status) values('11', 'Bada Hakim::::बडा हाकिमको कायार्लय', 'c');
insert into party.id_office_type(code, display_value, status) values('12', 'HMG::::नेपाल सरकार', 'c');
insert into party.id_office_type(code, display_value, status) values('13', 'NGO::::जिल्ला शिक्षा कायर्लय', 'c');
insert into party.id_office_type(code, display_value, status) values('14', 'District Office::::जिल्ला कायार्लय', 'c');
insert into party.id_office_type(code, display_value, status) values('15', 'Rinance::::काठमाण्डौ नगरपालिका', 'c');
insert into party.id_office_type(code, display_value, status) values('16', 'Gwosara::::गोश्वारा', 'c');
insert into party.id_office_type(code, display_value, status) values('17', 'Bhoomi Sudhar Mantralaya::::भूमि सुधार मन्त्रालय', 'c');
insert into party.id_office_type(code, display_value, status) values('18', 'Mal Pot Karrjyalaya::::मालपोत कायार्लय', 'c');
insert into party.id_office_type(code, display_value, status) values('19', 'नखुलेको', 'c');
insert into party.id_office_type(code, display_value, status) values('2', 'Private Organizations::::इलाका प्रशासन कायार्ल', 'c');
insert into party.id_office_type(code, display_value, status) values('20', 'भूYसुचना तथा अभिलेख विभाग', 'c');
insert into party.id_office_type(code, display_value, status) values('21', 'विद्यालय', 'c');
insert into party.id_office_type(code, display_value, status) values('22', 'स्थानीय विकास मन्त्रालय', 'c');
insert into party.id_office_type(code, display_value, status) values('23', 'नगरपंचायत', 'c');
insert into party.id_office_type(code, display_value, status) values('24', 'कम्प्यूटर शखा', 'c');
insert into party.id_office_type(code, display_value, status) values('25', 'जिल्ला सहकारी कायार्लय', 'c');
insert into party.id_office_type(code, display_value, status) values('26', 'सहकारी विभाग', 'c');
insert into party.id_office_type(code, display_value, status) values('27', 'आन्तरिक राजश्व विभाग', 'c');
insert into party.id_office_type(code, display_value, status) values('28', 'कम्पनी रजिष्टारको कायार्लय', 'c');
insert into party.id_office_type(code, display_value, status) values('29', 'पञ्जिकाधिकारीको कायार्लय', 'c');
insert into party.id_office_type(code, display_value, status) values('3', 'Chief District Officer::::प्रमुख जिल्ला अधिकारी', 'c');
insert into party.id_office_type(code, display_value, status) values('30', 'क्षेत्रीय शिक्षा निदेर्शनालय', 'c');
insert into party.id_office_type(code, display_value, status) values('32', 'समाजकल्याण परिषद', 'c');
insert into party.id_office_type(code, display_value, status) values('33', 'उद्योग मंन्त्रालय', 'c');
insert into party.id_office_type(code, display_value, status) values('4', 'CC Issueing Mobile Team::::नागरीकता टोली', 'c');
insert into party.id_office_type(code, display_value, status) values('5', 'Local Admin. Office::::नेपाल राष्ट्र बैंक', 'c');
insert into party.id_office_type(code, display_value, status) values('6', 'Zonal Commisoner Office::::अंचलाधिशको कायार्लय', 'c');
insert into party.id_office_type(code, display_value, status) values('7', 'Home Ministry::::गृह मंत्रालय', 'c');
insert into party.id_office_type(code, display_value, status) values('8', 'Corporations::::संस्थान (गुठी)', 'c');
insert into party.id_office_type(code, display_value, status) values('9', 'District Panchayt Office::::जिल्ला पञ्चायत कायार्लय', 'c');



--Table administrative.tenancy_type ----
DROP TABLE IF EXISTS administrative.tenancy_type CASCADE;
CREATE TABLE administrative.tenancy_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) NOT NULL DEFAULT ('c'),

    -- Internal constraints
    
    CONSTRAINT tenancy_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT tenancy_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table administrative.tenancy_type -- 
insert into administrative.tenancy_type(code, display_value, description, status) values('3301', 'TC1::::दतार्वाला', '', 'c');
insert into administrative.tenancy_type(code, display_value, status) values('3302', 'TC2::::जोताहा', 'c');



--Table system.vdc_appuser ----
DROP TABLE IF EXISTS system.vdc_appuser CASCADE;
CREATE TABLE system.vdc_appuser(
    id varchar(40) NOT NULL,
    vdc_code varchar(20) NOT NULL,
    ward_no varchar(10),
    appuser_id varchar(40) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT vdc_appuser_unique_vdc_ward_user UNIQUE (vdc_code, ward_no, appuser_id),
    CONSTRAINT vdc_appuser_pkey PRIMARY KEY (id)
);

    
 -- Data for the table system.vdc_appuser -- 
insert into system.vdc_appuser(id, vdc_code, appuser_id) values('vdc1', '43055', 'test-id');
insert into system.vdc_appuser(id, vdc_code, appuser_id) values('vdc2', '27009', 'test-id');



--Table party.grandfather_type ----
DROP TABLE IF EXISTS party.grandfather_type CASCADE;
CREATE TABLE party.grandfather_type(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1) DEFAULT ('c'),

    -- Internal constraints
    
    CONSTRAINT grandfather_type_display_value_unique UNIQUE (display_value),
    CONSTRAINT grandfather_type_pkey PRIMARY KEY (code)
);

    
 -- Data for the table party.grandfather_type -- 
insert into party.grandfather_type(code, display_value, status) values('3601', 'Father::::बाबु', 'c');
insert into party.grandfather_type(code, display_value, status) values('3602', 'Husband::::पति', 'c');
insert into party.grandfather_type(code, display_value, status) values('3603', 'Grand Father::::बाजे', 'c');
insert into party.grandfather_type(code, display_value, status) values('3604', 'Father in Law::::ससुरा', 'c');
insert into party.grandfather_type(code, display_value, status) values('3605', 'बाबु बाजे::::बाबु  पति', 'c');
insert into party.grandfather_type(code, display_value, status) values('3606', 'पिता ससुरा::::पिता ससुरा', 'c');



--Table cadastre.dataset ----
DROP TABLE IF EXISTS cadastre.dataset CASCADE;
CREATE TABLE cadastre.dataset(
    id varchar(40) NOT NULL DEFAULT (uuid_generate_v1()),
    name varchar(255) NOT NULL,
    srid integer NOT NULL,
    office_code varchar(20) NOT NULL,
    vdc_code varchar(20) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT dataset_unique_dataset_name UNIQUE (name, office_code),
    CONSTRAINT dataset_pkey PRIMARY KEY (id)
);

    
--Table system.approle_appgroup ----
DROP TABLE IF EXISTS system.approle_appgroup CASCADE;
CREATE TABLE system.approle_appgroup(
    approle_code varchar(20) NOT NULL,
    appgroup_id varchar(40) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT approle_appgroup_pkey PRIMARY KEY (approle_code,appgroup_id)
);

    
 -- Data for the table system.approle_appgroup -- 
insert into system.approle_appgroup(approle_code, appgroup_id) values('ApplnView', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ApplnCreate', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ApplnStatus', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ApplnAssignDeprt', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ApplnAssignAll', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('CancelService', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('RevertService', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ApplnApprove', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ApplnReject', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ApplnValidate', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ApplnArchive', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('BaunitSave', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('BaunitCertificate', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('BaunitSearch', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('TransactionCommit', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ViewMap', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('PrintMap', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ParcelSave', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('PartySave', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('SourceSave', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('SourceSearch', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('SourcePrint', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ReportGenerate', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ArchiveApps', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ManageSecurity', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ManageRefdata', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ManageSettings', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ApplnEdit', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ManageBR', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('MapSheetSave', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('ParcelDetailsSave', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('RHSave', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('MothManagement', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('RestrictionSearch', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('PrintRestrLetter', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('DoRegServices', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('DoCadastreServices', 'super-group-id');
insert into system.approle_appgroup(approle_code, appgroup_id) values('DoInfoServices', 'super-group-id');



--Table party.party_category ----
DROP TABLE IF EXISTS party.party_category CASCADE;
CREATE TABLE party.party_category(
    code varchar(20) NOT NULL,
    display_value varchar(250) NOT NULL,
    description varchar(555),
    status char(1),

    -- Internal constraints
    
    CONSTRAINT party_category_display_value_unique UNIQUE (display_value),
    CONSTRAINT party_category_pkey PRIMARY KEY (code)
);

    
--Table party.party_category_for_party ----
DROP TABLE IF EXISTS party.party_category_for_party CASCADE;
CREATE TABLE party.party_category_for_party(
    party_categorycode varchar(20) NOT NULL,
    partyid varchar(40) NOT NULL,

    -- Internal constraints
    
    CONSTRAINT party_category_for_party_pkey PRIMARY KEY (party_categorycode,partyid)
);

    

ALTER TABLE source.spatial_source ADD CONSTRAINT spatial_source_type_code_fk0 
            FOREIGN KEY (type_code) REFERENCES source.spatial_source_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX spatial_source_type_code_fk0_ind ON source.spatial_source (type_code);

ALTER TABLE source.spatial_source_measurement ADD CONSTRAINT spatial_source_measurement_spatial_source_id_fk1 
            FOREIGN KEY (spatial_source_id) REFERENCES source.spatial_source(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX spatial_source_measurement_spatial_source_id_fk1_ind ON source.spatial_source_measurement (spatial_source_id);

ALTER TABLE party.party ADD CONSTRAINT party_type_code_fk2 
            FOREIGN KEY (type_code) REFERENCES party.party_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_type_code_fk2_ind ON party.party (type_code);

ALTER TABLE party.group_party ADD CONSTRAINT group_party_type_code_fk3 
            FOREIGN KEY (type_code) REFERENCES party.group_party_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX group_party_type_code_fk3_ind ON party.group_party (type_code);

ALTER TABLE party.party_member ADD CONSTRAINT party_member_party_id_fk4 
            FOREIGN KEY (party_id) REFERENCES party.party(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX party_member_party_id_fk4_ind ON party.party_member (party_id);

ALTER TABLE party.party_member ADD CONSTRAINT party_member_group_id_fk5 
            FOREIGN KEY (group_id) REFERENCES party.group_party(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX party_member_group_id_fk5_ind ON party.party_member (group_id);

ALTER TABLE administrative.ba_unit ADD CONSTRAINT ba_unit_type_code_fk6 
            FOREIGN KEY (type_code) REFERENCES administrative.ba_unit_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX ba_unit_type_code_fk6_ind ON administrative.ba_unit (type_code);

ALTER TABLE administrative.rrr ADD CONSTRAINT rrr_ba_unit_id_fk7 
            FOREIGN KEY (ba_unit_id) REFERENCES administrative.ba_unit(id) ON UPDATE CASCADE ON DELETE Cascade;
CREATE INDEX rrr_ba_unit_id_fk7_ind ON administrative.rrr (ba_unit_id);

ALTER TABLE administrative.rrr_type ADD CONSTRAINT rrr_type_rrr_group_type_code_fk8 
            FOREIGN KEY (rrr_group_type_code) REFERENCES administrative.rrr_group_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX rrr_type_rrr_group_type_code_fk8_ind ON administrative.rrr_type (rrr_group_type_code);

ALTER TABLE administrative.rrr ADD CONSTRAINT rrr_type_code_fk9 
            FOREIGN KEY (type_code) REFERENCES administrative.rrr_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX rrr_type_code_fk9_ind ON administrative.rrr (type_code);

ALTER TABLE party.group_party ADD CONSTRAINT group_party_id_fk10 
            FOREIGN KEY (id) REFERENCES party.party(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX group_party_id_fk10_ind ON party.group_party (id);

ALTER TABLE source.spatial_source ADD CONSTRAINT spatial_source_id_fk11 
            FOREIGN KEY (id) REFERENCES source.source(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX spatial_source_id_fk11_ind ON source.spatial_source (id);

ALTER TABLE administrative.source_describes_rrr ADD CONSTRAINT source_describes_rrr_rrr_id_fk12 
            FOREIGN KEY (rrr_id) REFERENCES administrative.rrr(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX source_describes_rrr_rrr_id_fk12_ind ON administrative.source_describes_rrr (rrr_id);

ALTER TABLE administrative.source_describes_ba_unit ADD CONSTRAINT source_describes_ba_unit_ba_unit_id_fk13 
            FOREIGN KEY (ba_unit_id) REFERENCES administrative.ba_unit(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX source_describes_ba_unit_ba_unit_id_fk13_ind ON administrative.source_describes_ba_unit (ba_unit_id);

ALTER TABLE administrative.required_relationship_baunit ADD CONSTRAINT required_relationship_baunit_from_ba_unit_id_fk14 
            FOREIGN KEY (from_ba_unit_id) REFERENCES administrative.ba_unit(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX required_relationship_baunit_from_ba_unit_id_fk14_ind ON administrative.required_relationship_baunit (from_ba_unit_id);

ALTER TABLE administrative.required_relationship_baunit ADD CONSTRAINT required_relationship_baunit_to_ba_unit_id_fk15 
            FOREIGN KEY (to_ba_unit_id) REFERENCES administrative.ba_unit(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX required_relationship_baunit_to_ba_unit_id_fk15_ind ON administrative.required_relationship_baunit (to_ba_unit_id);

ALTER TABLE cadastre.spatial_value_area ADD CONSTRAINT spatial_value_area_spatial_unit_id_fk16 
            FOREIGN KEY (spatial_unit_id) REFERENCES cadastre.spatial_unit(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX spatial_value_area_spatial_unit_id_fk16_ind ON cadastre.spatial_value_area (spatial_unit_id);

ALTER TABLE cadastre.spatial_value_area ADD CONSTRAINT spatial_value_area_type_code_fk17 
            FOREIGN KEY (type_code) REFERENCES cadastre.area_type(code) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX spatial_value_area_type_code_fk17_ind ON cadastre.spatial_value_area (type_code);

ALTER TABLE cadastre.spatial_unit ADD CONSTRAINT spatial_unit_surface_relation_code_fk18 
            FOREIGN KEY (surface_relation_code) REFERENCES cadastre.surface_relation_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX spatial_unit_surface_relation_code_fk18_ind ON cadastre.spatial_unit (surface_relation_code);

ALTER TABLE cadastre.spatial_unit ADD CONSTRAINT spatial_unit_level_id_fk19 
            FOREIGN KEY (level_id) REFERENCES cadastre.level(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX spatial_unit_level_id_fk19_ind ON cadastre.spatial_unit (level_id);

ALTER TABLE cadastre.level ADD CONSTRAINT level_structure_code_fk20 
            FOREIGN KEY (structure_code) REFERENCES cadastre.structure_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX level_structure_code_fk20_ind ON cadastre.level (structure_code);

ALTER TABLE cadastre.level ADD CONSTRAINT level_register_type_code_fk21 
            FOREIGN KEY (register_type_code) REFERENCES cadastre.register_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX level_register_type_code_fk21_ind ON cadastre.level (register_type_code);

ALTER TABLE cadastre.level ADD CONSTRAINT level_type_code_fk22 
            FOREIGN KEY (type_code) REFERENCES cadastre.level_content_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX level_type_code_fk22_ind ON cadastre.level (type_code);

ALTER TABLE cadastre.spatial_unit_group ADD CONSTRAINT spatial_unit_group_found_in_spatial_unit_group_id_fk23 
            FOREIGN KEY (found_in_spatial_unit_group_id) REFERENCES cadastre.spatial_unit_group(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX spatial_unit_group_found_in_spatial_unit_group_id_fk23_ind ON cadastre.spatial_unit_group (found_in_spatial_unit_group_id);

ALTER TABLE cadastre.spatial_unit_in_group ADD CONSTRAINT spatial_unit_in_group_spatial_unit_group_id_fk24 
            FOREIGN KEY (spatial_unit_group_id) REFERENCES cadastre.spatial_unit_group(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX spatial_unit_in_group_spatial_unit_group_id_fk24_ind ON cadastre.spatial_unit_in_group (spatial_unit_group_id);

ALTER TABLE cadastre.spatial_unit_in_group ADD CONSTRAINT spatial_unit_in_group_spatial_unit_id_fk25 
            FOREIGN KEY (spatial_unit_id) REFERENCES cadastre.spatial_unit(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX spatial_unit_in_group_spatial_unit_id_fk25_ind ON cadastre.spatial_unit_in_group (spatial_unit_id);

ALTER TABLE cadastre.legal_space_utility_network ADD CONSTRAINT legal_space_utility_network_status_code_fk26 
            FOREIGN KEY (status_code) REFERENCES cadastre.area_unit_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX legal_space_utility_network_status_code_fk26_ind ON cadastre.legal_space_utility_network (status_code);

ALTER TABLE cadastre.legal_space_utility_network ADD CONSTRAINT legal_space_utility_network_type_code_fk27 
            FOREIGN KEY (type_code) REFERENCES cadastre.utility_network_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX legal_space_utility_network_type_code_fk27_ind ON cadastre.legal_space_utility_network (type_code);

ALTER TABLE application.request_type ADD CONSTRAINT request_type_request_category_code_fk28 
            FOREIGN KEY (request_category_code) REFERENCES application.request_category_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX request_type_request_category_code_fk28_ind ON application.request_type (request_category_code);

ALTER TABLE application.service ADD CONSTRAINT service_application_id_fk29 
            FOREIGN KEY (application_id) REFERENCES application.application(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX service_application_id_fk29_ind ON application.service (application_id);

ALTER TABLE application.service ADD CONSTRAINT service_request_type_code_fk30 
            FOREIGN KEY (request_type_code) REFERENCES application.request_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX service_request_type_code_fk30_ind ON application.service (request_type_code);

ALTER TABLE party.party_role ADD CONSTRAINT party_role_type_code_fk31 
            FOREIGN KEY (type_code) REFERENCES party.party_role_type(code) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX party_role_type_code_fk31_ind ON party.party_role (type_code);

ALTER TABLE party.party_role ADD CONSTRAINT party_role_party_id_fk32 
            FOREIGN KEY (party_id) REFERENCES party.party(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX party_role_party_id_fk32_ind ON party.party_role (party_id);

ALTER TABLE application.application ADD CONSTRAINT application_agent_id_fk33 
            FOREIGN KEY (agent_id) REFERENCES party.party(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX application_agent_id_fk33_ind ON application.application (agent_id);

ALTER TABLE party.party ADD CONSTRAINT party_address_id_fk34 
            FOREIGN KEY (address_id) REFERENCES address.address(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_address_id_fk34_ind ON party.party (address_id);

ALTER TABLE cadastre.spatial_unit ADD CONSTRAINT spatial_unit_dimension_code_fk35 
            FOREIGN KEY (dimension_code) REFERENCES cadastre.dimension_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX spatial_unit_dimension_code_fk35_ind ON cadastre.spatial_unit (dimension_code);

ALTER TABLE party.party ADD CONSTRAINT party_preferred_communication_code_fk36 
            FOREIGN KEY (preferred_communication_code) REFERENCES party.communication_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_preferred_communication_code_fk36_ind ON party.party (preferred_communication_code);

ALTER TABLE application.application ADD CONSTRAINT application_contact_person_id_fk37 
            FOREIGN KEY (contact_person_id) REFERENCES party.party(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX application_contact_person_id_fk37_ind ON application.application (contact_person_id);

ALTER TABLE source.source ADD CONSTRAINT source_maintype_fk38 
            FOREIGN KEY (maintype) REFERENCES source.presentation_form_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX source_maintype_fk38_ind ON source.source (maintype);

ALTER TABLE source.source ADD CONSTRAINT source_archive_id_fk39 
            FOREIGN KEY (archive_id) REFERENCES source.archive(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX source_archive_id_fk39_ind ON source.source (archive_id);

ALTER TABLE application.application ADD CONSTRAINT application_action_code_fk40 
            FOREIGN KEY (action_code) REFERENCES application.application_action_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX application_action_code_fk40_ind ON application.application (action_code);

ALTER TABLE application.service ADD CONSTRAINT service_status_code_fk41 
            FOREIGN KEY (status_code) REFERENCES application.service_status_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX service_status_code_fk41_ind ON application.service (status_code);

ALTER TABLE party.party ADD CONSTRAINT party_id_type_code_fk42 
            FOREIGN KEY (id_type_code) REFERENCES party.id_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_id_type_code_fk42_ind ON party.party (id_type_code);

ALTER TABLE application.service ADD CONSTRAINT service_action_code_fk43 
            FOREIGN KEY (action_code) REFERENCES application.service_action_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX service_action_code_fk43_ind ON application.service (action_code);

ALTER TABLE application.application_property ADD CONSTRAINT application_property_application_id_fk44 
            FOREIGN KEY (application_id) REFERENCES application.application(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX application_property_application_id_fk44_ind ON application.application_property (application_id);

ALTER TABLE application.application_uses_source ADD CONSTRAINT application_uses_source_source_id_fk45 
            FOREIGN KEY (source_id) REFERENCES source.source(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX application_uses_source_source_id_fk45_ind ON application.application_uses_source (source_id);

ALTER TABLE application.application_uses_source ADD CONSTRAINT application_uses_source_application_id_fk46 
            FOREIGN KEY (application_id) REFERENCES application.application(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX application_uses_source_application_id_fk46_ind ON application.application_uses_source (application_id);

ALTER TABLE application.request_type_requires_source_type ADD CONSTRAINT request_type_requires_source_type_request_type_code_fk47 
            FOREIGN KEY (request_type_code) REFERENCES application.request_type(code) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX request_type_requires_source_type_request_type_code_fk47_ind ON application.request_type_requires_source_type (request_type_code);

ALTER TABLE application.application_property ADD CONSTRAINT application_property_ba_unit_id_fk48 
            FOREIGN KEY (ba_unit_id) REFERENCES administrative.ba_unit(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX application_property_ba_unit_id_fk48_ind ON application.application_property (ba_unit_id);

ALTER TABLE application.application ADD CONSTRAINT application_assignee_id_fk49 
            FOREIGN KEY (assignee_id) REFERENCES system.appuser(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX application_assignee_id_fk49_ind ON application.application (assignee_id);

ALTER TABLE application.application ADD CONSTRAINT application_status_code_fk50 
            FOREIGN KEY (status_code) REFERENCES application.application_status_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX application_status_code_fk50_ind ON application.application (status_code);

ALTER TABLE system.appuser_setting ADD CONSTRAINT appuser_setting_user_id_fk51 
            FOREIGN KEY (user_id) REFERENCES system.appuser(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX appuser_setting_user_id_fk51_ind ON system.appuser_setting (user_id);

ALTER TABLE source.source ADD CONSTRAINT source_availability_status_code_fk52 
            FOREIGN KEY (availability_status_code) REFERENCES source.availability_status_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX source_availability_status_code_fk52_ind ON source.source (availability_status_code);

ALTER TABLE source.source ADD CONSTRAINT source_type_code_fk53 
            FOREIGN KEY (type_code) REFERENCES source.administrative_source_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX source_type_code_fk53_ind ON source.source (type_code);

ALTER TABLE application.request_type_requires_source_type ADD CONSTRAINT request_type_requires_source_type_source_type_code_fk54 
            FOREIGN KEY (source_type_code) REFERENCES source.administrative_source_type(code) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX request_type_requires_source_type_source_type_code_fk54_ind ON application.request_type_requires_source_type (source_type_code);

ALTER TABLE system.config_map_layer ADD CONSTRAINT config_map_layer_type_code_fk55 
            FOREIGN KEY (type_code) REFERENCES system.config_map_layer_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX config_map_layer_type_code_fk55_ind ON system.config_map_layer (type_code);

ALTER TABLE administrative.ba_unit_as_party ADD CONSTRAINT ba_unit_as_party_party_id_fk56 
            FOREIGN KEY (party_id) REFERENCES party.party(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX ba_unit_as_party_party_id_fk56_ind ON administrative.ba_unit_as_party (party_id);

ALTER TABLE administrative.ba_unit_as_party ADD CONSTRAINT ba_unit_as_party_ba_unit_id_fk57 
            FOREIGN KEY (ba_unit_id) REFERENCES administrative.ba_unit(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX ba_unit_as_party_ba_unit_id_fk57_ind ON administrative.ba_unit_as_party (ba_unit_id);

ALTER TABLE system.br ADD CONSTRAINT br_technical_type_code_fk58 
            FOREIGN KEY (technical_type_code) REFERENCES system.br_technical_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX br_technical_type_code_fk58_ind ON system.br (technical_type_code);

ALTER TABLE system.br_validation ADD CONSTRAINT br_validation_br_id_fk59 
            FOREIGN KEY (br_id) REFERENCES system.br(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX br_validation_br_id_fk59_ind ON system.br_validation (br_id);

ALTER TABLE system.br_definition ADD CONSTRAINT br_definition_br_id_fk60 
            FOREIGN KEY (br_id) REFERENCES system.br(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX br_definition_br_id_fk60_ind ON system.br_definition (br_id);

ALTER TABLE system.br_validation ADD CONSTRAINT br_validation_severity_code_fk61 
            FOREIGN KEY (severity_code) REFERENCES system.br_severity_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX br_validation_severity_code_fk61_ind ON system.br_validation (severity_code);

ALTER TABLE system.br_validation ADD CONSTRAINT br_validation_target_code_fk62 
            FOREIGN KEY (target_code) REFERENCES system.br_validation_target_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX br_validation_target_code_fk62_ind ON system.br_validation (target_code);

ALTER TABLE system.br_validation ADD CONSTRAINT br_validation_target_rrr_type_code_fk63 
            FOREIGN KEY (target_rrr_type_code) REFERENCES administrative.rrr_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX br_validation_target_rrr_type_code_fk63_ind ON system.br_validation (target_rrr_type_code);

ALTER TABLE administrative.rrr ADD CONSTRAINT rrr_status_code_fk64 
            FOREIGN KEY (status_code) REFERENCES transaction.reg_status_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX rrr_status_code_fk64_ind ON administrative.rrr (status_code);

ALTER TABLE administrative.ba_unit ADD CONSTRAINT ba_unit_status_code_fk65 
            FOREIGN KEY (status_code) REFERENCES transaction.reg_status_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX ba_unit_status_code_fk65_ind ON administrative.ba_unit (status_code);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_id_fk66 
            FOREIGN KEY (id) REFERENCES cadastre.spatial_unit(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX cadastre_object_id_fk66_ind ON cadastre.cadastre_object (id);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_status_code_fk67 
            FOREIGN KEY (status_code) REFERENCES transaction.reg_status_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_status_code_fk67_ind ON cadastre.cadastre_object (status_code);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_type_code_fk68 
            FOREIGN KEY (type_code) REFERENCES cadastre.cadastre_object_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_type_code_fk68_ind ON cadastre.cadastre_object (type_code);

ALTER TABLE cadastre.legal_space_utility_network ADD CONSTRAINT legal_space_utility_network_id_fk69 
            FOREIGN KEY (id) REFERENCES cadastre.cadastre_object(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX legal_space_utility_network_id_fk69_ind ON cadastre.legal_space_utility_network (id);

ALTER TABLE administrative.source_describes_ba_unit ADD CONSTRAINT source_describes_ba_unit_source_id_fk70 
            FOREIGN KEY (source_id) REFERENCES source.source(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX source_describes_ba_unit_source_id_fk70_ind ON administrative.source_describes_ba_unit (source_id);

ALTER TABLE administrative.required_relationship_baunit ADD CONSTRAINT required_relationship_baunit_relation_code_fk71 
            FOREIGN KEY (relation_code) REFERENCES administrative.ba_unit_rel_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX required_relationship_baunit_relation_code_fk71_ind ON administrative.required_relationship_baunit (relation_code);

ALTER TABLE administrative.notation ADD CONSTRAINT notation_status_code_fk72 
            FOREIGN KEY (status_code) REFERENCES transaction.reg_status_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX notation_status_code_fk72_ind ON administrative.notation (status_code);

ALTER TABLE administrative.notation ADD CONSTRAINT notation_ba_unit_id_fk73 
            FOREIGN KEY (ba_unit_id) REFERENCES administrative.ba_unit(id) ON UPDATE CASCADE ON DELETE Cascade;
CREATE INDEX notation_ba_unit_id_fk73_ind ON administrative.notation (ba_unit_id);

ALTER TABLE administrative.rrr_share ADD CONSTRAINT rrr_share_rrr_id_fk74 
            FOREIGN KEY (rrr_id) REFERENCES administrative.rrr(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX rrr_share_rrr_id_fk74_ind ON administrative.rrr_share (rrr_id);

ALTER TABLE administrative.party_for_rrr ADD CONSTRAINT party_for_rrr_rrr_id_fk75 
            FOREIGN KEY (rrr_id,share_id) REFERENCES administrative.rrr_share(rrr_id,id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX party_for_rrr_rrr_id_fk75_ind ON administrative.party_for_rrr (rrr_id,share_id);

ALTER TABLE transaction.transaction ADD CONSTRAINT transaction_from_service_id_fk76 
            FOREIGN KEY (from_service_id) REFERENCES application.service(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX transaction_from_service_id_fk76_ind ON transaction.transaction (from_service_id);

ALTER TABLE administrative.notation ADD CONSTRAINT notation_transaction_id_fk77 
            FOREIGN KEY (transaction_id) REFERENCES transaction.transaction(id) ON UPDATE CASCADE ON DELETE Cascade;
CREATE INDEX notation_transaction_id_fk77_ind ON administrative.notation (transaction_id);

ALTER TABLE administrative.source_describes_rrr ADD CONSTRAINT source_describes_rrr_source_id_fk78 
            FOREIGN KEY (source_id) REFERENCES source.source(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX source_describes_rrr_source_id_fk78_ind ON administrative.source_describes_rrr (source_id);

ALTER TABLE administrative.party_for_rrr ADD CONSTRAINT party_for_rrr_party_id_fk79 
            FOREIGN KEY (party_id) REFERENCES party.party(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX party_for_rrr_party_id_fk79_ind ON administrative.party_for_rrr (party_id);

ALTER TABLE transaction.transaction ADD CONSTRAINT transaction_status_code_fk80 
            FOREIGN KEY (status_code) REFERENCES transaction.transaction_status_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX transaction_status_code_fk80_ind ON transaction.transaction (status_code);

ALTER TABLE application.request_type ADD CONSTRAINT request_type_rrr_type_code_fk81 
            FOREIGN KEY (rrr_type_code) REFERENCES administrative.rrr_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX request_type_rrr_type_code_fk81_ind ON application.request_type (rrr_type_code);

ALTER TABLE application.request_type ADD CONSTRAINT request_type_type_action_code_fk82 
            FOREIGN KEY (type_action_code) REFERENCES application.type_action(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX request_type_type_action_code_fk82_ind ON application.request_type (type_action_code);

ALTER TABLE administrative.rrr ADD CONSTRAINT rrr_mortgage_type_code_fk83 
            FOREIGN KEY (mortgage_type_code) REFERENCES administrative.mortgage_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX rrr_mortgage_type_code_fk83_ind ON administrative.rrr (mortgage_type_code);

ALTER TABLE administrative.rrr ADD CONSTRAINT rrr_transaction_id_fk84 
            FOREIGN KEY (transaction_id) REFERENCES transaction.transaction(id) ON UPDATE CASCADE ON DELETE Cascade;
CREATE INDEX rrr_transaction_id_fk84_ind ON administrative.rrr (transaction_id);

ALTER TABLE administrative.ba_unit ADD CONSTRAINT ba_unit_transaction_id_fk85 
            FOREIGN KEY (transaction_id) REFERENCES transaction.transaction(id) ON UPDATE CASCADE ON DELETE Cascade;
CREATE INDEX ba_unit_transaction_id_fk85_ind ON administrative.ba_unit (transaction_id);

ALTER TABLE administrative.party_for_rrr ADD CONSTRAINT party_for_rrr_rrr_id_fk86 
            FOREIGN KEY (rrr_id) REFERENCES administrative.rrr(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX party_for_rrr_rrr_id_fk86_ind ON administrative.party_for_rrr (rrr_id);

ALTER TABLE administrative.notation ADD CONSTRAINT notation_rrr_id_fk87 
            FOREIGN KEY (rrr_id) REFERENCES administrative.rrr(id) ON UPDATE CASCADE ON DELETE Cascade;
CREATE INDEX notation_rrr_id_fk87_ind ON administrative.notation (rrr_id);

ALTER TABLE source.source ADD CONSTRAINT source_transaction_id_fk88 
            FOREIGN KEY (transaction_id) REFERENCES transaction.transaction(id) ON UPDATE CASCADE ON DELETE Cascade;
CREATE INDEX source_transaction_id_fk88_ind ON source.source (transaction_id);

ALTER TABLE source.source ADD CONSTRAINT source_status_code_fk89 
            FOREIGN KEY (status_code) REFERENCES transaction.reg_status_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX source_status_code_fk89_ind ON source.source (status_code);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_building_unit_type_code_fk90 
            FOREIGN KEY (building_unit_type_code) REFERENCES cadastre.building_unit_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_building_unit_type_code_fk90_ind ON cadastre.cadastre_object (building_unit_type_code);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_transaction_id_fk91 
            FOREIGN KEY (transaction_id) REFERENCES transaction.transaction(id) ON UPDATE CASCADE ON DELETE Cascade;
CREATE INDEX cadastre_object_transaction_id_fk91_ind ON cadastre.cadastre_object (transaction_id);

ALTER TABLE cadastre.cadastre_object_target ADD CONSTRAINT cadastre_object_target_cadastre_object_id_fk92 
            FOREIGN KEY (cadastre_object_id) REFERENCES cadastre.cadastre_object(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX cadastre_object_target_cadastre_object_id_fk92_ind ON cadastre.cadastre_object_target (cadastre_object_id);

ALTER TABLE party.party ADD CONSTRAINT party_gender_code_fk93 
            FOREIGN KEY (gender_code) REFERENCES party.gender_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_gender_code_fk93_ind ON party.party (gender_code);

ALTER TABLE cadastre.survey_point ADD CONSTRAINT survey_point_transaction_id_fk94 
            FOREIGN KEY (transaction_id) REFERENCES transaction.transaction(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX survey_point_transaction_id_fk94_ind ON cadastre.survey_point (transaction_id);

ALTER TABLE cadastre.cadastre_object_target ADD CONSTRAINT cadastre_object_target_transaction_id_fk95 
            FOREIGN KEY (transaction_id) REFERENCES transaction.transaction(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX cadastre_object_target_transaction_id_fk95_ind ON cadastre.cadastre_object_target (transaction_id);

ALTER TABLE transaction.transaction_source ADD CONSTRAINT transaction_source_transaction_id_fk96 
            FOREIGN KEY (transaction_id) REFERENCES transaction.transaction(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX transaction_source_transaction_id_fk96_ind ON transaction.transaction_source (transaction_id);

ALTER TABLE transaction.transaction_source ADD CONSTRAINT transaction_source_source_id_fk97 
            FOREIGN KEY (source_id) REFERENCES source.source(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX transaction_source_source_id_fk97_ind ON transaction.transaction_source (source_id);

ALTER TABLE system.appuser_appgroup ADD CONSTRAINT appuser_appgroup_appuser_id_fk98 
            FOREIGN KEY (appuser_id) REFERENCES system.appuser(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX appuser_appgroup_appuser_id_fk98_ind ON system.appuser_appgroup (appuser_id);

ALTER TABLE system.appuser_appgroup ADD CONSTRAINT appuser_appgroup_appgroup_id_fk99 
            FOREIGN KEY (appgroup_id) REFERENCES system.appgroup(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX appuser_appgroup_appgroup_id_fk99_ind ON system.appuser_appgroup (appgroup_id);

ALTER TABLE system.approle_appgroup ADD CONSTRAINT approle_appgroup_appgroup_id_fk100 
            FOREIGN KEY (appgroup_id) REFERENCES system.appgroup(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX approle_appgroup_appgroup_id_fk100_ind ON system.approle_appgroup (appgroup_id);

ALTER TABLE system.approle_appgroup ADD CONSTRAINT approle_appgroup_approle_code_fk101 
            FOREIGN KEY (approle_code) REFERENCES system.approle(code) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX approle_appgroup_approle_code_fk101_ind ON system.approle_appgroup (approle_code);

ALTER TABLE application.service_action_type ADD CONSTRAINT service_action_type_status_to_set_fk102 
            FOREIGN KEY (status_to_set) REFERENCES application.service_status_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX service_action_type_status_to_set_fk102_ind ON application.service_action_type (status_to_set);

ALTER TABLE application.application_action_type ADD CONSTRAINT application_action_type_status_to_set_fk103 
            FOREIGN KEY (status_to_set) REFERENCES application.application_status_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX application_action_type_status_to_set_fk103_ind ON application.application_action_type (status_to_set);

ALTER TABLE system.br_validation ADD CONSTRAINT br_validation_target_application_moment_fk104 
            FOREIGN KEY (target_application_moment) REFERENCES application.application_action_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX br_validation_target_application_moment_fk104_ind ON system.br_validation (target_application_moment);

ALTER TABLE system.br_validation ADD CONSTRAINT br_validation_target_service_moment_fk105 
            FOREIGN KEY (target_service_moment) REFERENCES application.service_action_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX br_validation_target_service_moment_fk105_ind ON system.br_validation (target_service_moment);

ALTER TABLE system.br_validation ADD CONSTRAINT br_validation_target_reg_moment_fk106 
            FOREIGN KEY (target_reg_moment) REFERENCES transaction.reg_status_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX br_validation_target_reg_moment_fk106_ind ON system.br_validation (target_reg_moment);

ALTER TABLE system.query_field ADD CONSTRAINT query_field_query_name_fk107 
            FOREIGN KEY (query_name) REFERENCES system.query(name) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX query_field_query_name_fk107_ind ON system.query_field (query_name);

ALTER TABLE system.config_map_layer ADD CONSTRAINT config_map_layer_pojo_query_name_fk108 
            FOREIGN KEY (pojo_query_name) REFERENCES system.query(name) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX config_map_layer_pojo_query_name_fk108_ind ON system.config_map_layer (pojo_query_name);

ALTER TABLE system.config_map_layer ADD CONSTRAINT config_map_layer_pojo_query_name_for_select_fk109 
            FOREIGN KEY (pojo_query_name_for_select) REFERENCES system.query(name) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX config_map_layer_pojo_query_name_for_select_fk109_ind ON system.config_map_layer (pojo_query_name_for_select);

ALTER TABLE cadastre.cadastre_object_node_target ADD CONSTRAINT cadastre_object_node_target_transaction_id_fk110 
            FOREIGN KEY (transaction_id) REFERENCES transaction.transaction(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX cadastre_object_node_target_transaction_id_fk110_ind ON cadastre.cadastre_object_node_target (transaction_id);

ALTER TABLE administrative.ba_unit_target ADD CONSTRAINT ba_unit_target_ba_unit_id_fk111 
            FOREIGN KEY (ba_unit_id) REFERENCES administrative.ba_unit(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX ba_unit_target_ba_unit_id_fk111_ind ON administrative.ba_unit_target (ba_unit_id);

ALTER TABLE administrative.ba_unit_target ADD CONSTRAINT ba_unit_target_transaction_id_fk112 
            FOREIGN KEY (transaction_id) REFERENCES transaction.transaction(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX ba_unit_target_transaction_id_fk112_ind ON administrative.ba_unit_target (transaction_id);

ALTER TABLE cadastre.segments ADD CONSTRAINT segments_id_fk113 
            FOREIGN KEY (id) REFERENCES cadastre.cadastre_object(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX segments_id_fk113_ind ON cadastre.segments (id);

ALTER TABLE cadastre.verticalParcel ADD CONSTRAINT verticalParcel_id_fk114 
            FOREIGN KEY (id) REFERENCES cadastre.cadastre_object(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX verticalParcel_id_fk114_ind ON cadastre.verticalParcel (id);

ALTER TABLE cadastre.construction ADD CONSTRAINT construction_id_fk115 
            FOREIGN KEY (id) REFERENCES cadastre.cadastre_object(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX construction_id_fk115_ind ON cadastre.construction (id);

ALTER TABLE cadastre.construction ADD CONSTRAINT construction_constype_fk116 
            FOREIGN KEY (constype) REFERENCES cadastre.construction_type(code) ON UPDATE Cascade ON DELETE RESTRICT;
CREATE INDEX construction_constype_fk116_ind ON cadastre.construction (constype);

ALTER TABLE cadastre.segments ADD CONSTRAINT segments_mbound_type_fk117 
            FOREIGN KEY (mbound_type) REFERENCES cadastre.map_boundary_type(code) ON UPDATE Cascade ON DELETE RESTRICT;
CREATE INDEX segments_mbound_type_fk117_ind ON cadastre.segments (mbound_type);

ALTER TABLE cadastre.segments ADD CONSTRAINT segments_abound_type_fk118 
            FOREIGN KEY (abound_type) REFERENCES cadastre.adminstrative_boundary_type(code) ON UPDATE Cascade ON DELETE RESTRICT;
CREATE INDEX segments_abound_type_fk118_ind ON cadastre.segments (abound_type);

ALTER TABLE cadastre.segments ADD CONSTRAINT segments_bound_type_fk119 
            FOREIGN KEY (bound_type) REFERENCES cadastre.boundary_type(code) ON UPDATE Cascade ON DELETE RESTRICT;
CREATE INDEX segments_bound_type_fk119_ind ON cadastre.segments (bound_type);

ALTER TABLE administrative.loc ADD CONSTRAINT loc_moth_id_fk120 
            FOREIGN KEY (moth_id) REFERENCES administrative.moth(id) ON UPDATE Cascade ON DELETE Cascade;
CREATE INDEX loc_moth_id_fk120_ind ON administrative.loc (moth_id);

ALTER TABLE system.office ADD CONSTRAINT office_district_code_fk121 
            FOREIGN KEY (district_code) REFERENCES address.district(code) ON UPDATE Cascade ON DELETE RESTRICT;
CREATE INDEX office_district_code_fk121_ind ON system.office (district_code);

ALTER TABLE address.vdc ADD CONSTRAINT vdc_district_code_fk122 
            FOREIGN KEY (district_code) REFERENCES address.district(code) ON UPDATE Cascade ON DELETE RESTRICT;
CREATE INDEX vdc_district_code_fk122_ind ON address.vdc (district_code);

ALTER TABLE system.department ADD CONSTRAINT department_office_code_fk123 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX department_office_code_fk123_ind ON system.department (office_code);

ALTER TABLE system.appuser ADD CONSTRAINT appuser_department_code_fk124 
            FOREIGN KEY (department_code) REFERENCES system.department(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX appuser_department_code_fk124_ind ON system.appuser (department_code);

ALTER TABLE system.department ADD CONSTRAINT department_office_code_fk125 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX department_office_code_fk125_ind ON system.department (office_code);

ALTER TABLE administrative.moth ADD CONSTRAINT moth_vdc_code_fk126 
            FOREIGN KEY (vdc_code) REFERENCES address.vdc(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX moth_vdc_code_fk126_ind ON administrative.moth (vdc_code);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_map_sheet_id_fk127 
            FOREIGN KEY (map_sheet_id) REFERENCES cadastre.map_sheet(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_map_sheet_id_fk127_ind ON cadastre.cadastre_object (map_sheet_id);

ALTER TABLE source.source ADD CONSTRAINT source_office_code_fk128 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX source_office_code_fk128_ind ON source.source (office_code);

ALTER TABLE document.document ADD CONSTRAINT document_office_code_fk129 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX document_office_code_fk129_ind ON document.document (office_code);

ALTER TABLE party.party ADD CONSTRAINT party_office_code_fk130 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_office_code_fk130_ind ON party.party (office_code);

ALTER TABLE administrative.ba_unit ADD CONSTRAINT ba_unit_office_code_fk131 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX ba_unit_office_code_fk131_ind ON administrative.ba_unit (office_code);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_office_code_fk132 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_office_code_fk132_ind ON cadastre.cadastre_object (office_code);

ALTER TABLE application.application ADD CONSTRAINT application_office_code_fk133 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX application_office_code_fk133_ind ON application.application (office_code);

ALTER TABLE system.br ADD CONSTRAINT br_office_code_fk134 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX br_office_code_fk134_ind ON system.br (office_code);

ALTER TABLE system.setting ADD CONSTRAINT setting_office_code_fk135 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX setting_office_code_fk135_ind ON system.setting (office_code);

ALTER TABLE administrative.moth ADD CONSTRAINT moth_office_code_fk136 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX moth_office_code_fk136_ind ON administrative.moth (office_code);

ALTER TABLE administrative.loc ADD CONSTRAINT loc_office_code_fk137 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX loc_office_code_fk137_ind ON administrative.loc (office_code);

ALTER TABLE cadastre.map_sheet ADD CONSTRAINT map_sheet_office_code_fk138 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX map_sheet_office_code_fk138_ind ON cadastre.map_sheet (office_code);

ALTER TABLE transaction.transaction ADD CONSTRAINT transaction_office_code_fk139 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX transaction_office_code_fk139_ind ON transaction.transaction (office_code);

ALTER TABLE address.address ADD CONSTRAINT address_vdc_code_fk140 
            FOREIGN KEY (vdc_code) REFERENCES address.vdc(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX address_vdc_code_fk140_ind ON address.address (vdc_code);

ALTER TABLE party.party ADD CONSTRAINT party_photo_id_fk141 
            FOREIGN KEY (photo_id) REFERENCES document.document(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_photo_id_fk141_ind ON party.party (photo_id);

ALTER TABLE party.party ADD CONSTRAINT party_left_finger_id_fk142 
            FOREIGN KEY (left_finger_id) REFERENCES document.document(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_left_finger_id_fk142_ind ON party.party (left_finger_id);

ALTER TABLE party.party ADD CONSTRAINT party_right_finger_id_fk143 
            FOREIGN KEY (right_finger_id) REFERENCES document.document(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_right_finger_id_fk143_ind ON party.party (right_finger_id);

ALTER TABLE party.party ADD CONSTRAINT party_signature_id_fk144 
            FOREIGN KEY (signature_id) REFERENCES document.document(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_signature_id_fk144_ind ON party.party (signature_id);

ALTER TABLE administrative.ba_unit ADD CONSTRAINT ba_unit_cadastre_object_id_fk145 
            FOREIGN KEY (cadastre_object_id) REFERENCES cadastre.cadastre_object(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX ba_unit_cadastre_object_id_fk145_ind ON administrative.ba_unit (cadastre_object_id);

ALTER TABLE administrative.rrr ADD CONSTRAINT rrr_loc_id_fk146 
            FOREIGN KEY (loc_id) REFERENCES administrative.loc(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX rrr_loc_id_fk146_ind ON administrative.rrr (loc_id);

ALTER TABLE administrative.rrr ADD CONSTRAINT rrr_restriction_reason_code_fk147 
            FOREIGN KEY (restriction_reason_code) REFERENCES administrative.restriction_reason(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX rrr_restriction_reason_code_fk147_ind ON administrative.rrr (restriction_reason_code);

ALTER TABLE administrative.rrr ADD CONSTRAINT rrr_office_code_fk148 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX rrr_office_code_fk148_ind ON administrative.rrr (office_code);

ALTER TABLE administrative.rrr ADD CONSTRAINT rrr_owner_type_code_fk149 
            FOREIGN KEY (owner_type_code) REFERENCES administrative.owner_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX rrr_owner_type_code_fk149_ind ON administrative.rrr (owner_type_code);

ALTER TABLE administrative.rrr ADD CONSTRAINT rrr_ownership_type_code_fk150 
            FOREIGN KEY (ownership_type_code) REFERENCES administrative.ownership_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX rrr_ownership_type_code_fk150_ind ON administrative.rrr (ownership_type_code);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_land_use_code_fk151 
            FOREIGN KEY (land_use_code) REFERENCES cadastre.land_use(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_land_use_code_fk151_ind ON cadastre.cadastre_object (land_use_code);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_land_type_code_fk152 
            FOREIGN KEY (land_type_code) REFERENCES cadastre.land_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_land_type_code_fk152_ind ON cadastre.cadastre_object (land_type_code);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_land_class_code_fk153 
            FOREIGN KEY (land_class_code) REFERENCES cadastre.land_class(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_land_class_code_fk153_ind ON cadastre.cadastre_object (land_class_code);

ALTER TABLE party.party ADD CONSTRAINT party_parent_id_fk154 
            FOREIGN KEY (parent_id) REFERENCES party.party(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_parent_id_fk154_ind ON party.party (parent_id);

ALTER TABLE party.party ADD CONSTRAINT party_id_office_district_code_fk155 
            FOREIGN KEY (id_office_district_code) REFERENCES address.district(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_id_office_district_code_fk155_ind ON party.party (id_office_district_code);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_map_sheet_id2_fk156 
            FOREIGN KEY (map_sheet_id2) REFERENCES cadastre.map_sheet(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_map_sheet_id2_fk156_ind ON cadastre.cadastre_object (map_sheet_id2);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_map_sheet_id3_fk157 
            FOREIGN KEY (map_sheet_id3) REFERENCES cadastre.map_sheet(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_map_sheet_id3_fk157_ind ON cadastre.cadastre_object (map_sheet_id3);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_map_sheet_id4_fk158 
            FOREIGN KEY (map_sheet_id4) REFERENCES cadastre.map_sheet(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_map_sheet_id4_fk158_ind ON cadastre.cadastre_object (map_sheet_id4);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_area_unit_type_code_fk159 
            FOREIGN KEY (area_unit_type_code) REFERENCES cadastre.area_unit_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_area_unit_type_code_fk159_ind ON cadastre.cadastre_object (area_unit_type_code);

ALTER TABLE administrative.rrr ADD CONSTRAINT rrr_restriction_release_reason_code_fk160 
            FOREIGN KEY (restriction_release_reason_code) REFERENCES administrative.restriction_release_reason(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX rrr_restriction_release_reason_code_fk160_ind ON administrative.rrr (restriction_release_reason_code);

ALTER TABLE party.party ADD CONSTRAINT party_id_office_type_code_fk161 
            FOREIGN KEY (id_office_type_code) REFERENCES party.id_office_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_id_office_type_code_fk161_ind ON party.party (id_office_type_code);

ALTER TABLE administrative.rrr ADD CONSTRAINT rrr_tenancy_type_code_fk162 
            FOREIGN KEY (tenancy_type_code) REFERENCES administrative.tenancy_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX rrr_tenancy_type_code_fk162_ind ON administrative.rrr (tenancy_type_code);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_fy_code_fk163 
            FOREIGN KEY (fy_code) REFERENCES system.financial_year(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_fy_code_fk163_ind ON cadastre.cadastre_object (fy_code);

ALTER TABLE administrative.ba_unit ADD CONSTRAINT ba_unit_fy_code_fk164 
            FOREIGN KEY (fy_code) REFERENCES system.financial_year(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX ba_unit_fy_code_fk164_ind ON administrative.ba_unit (fy_code);

ALTER TABLE administrative.rrr ADD CONSTRAINT rrr_fy_code_fk165 
            FOREIGN KEY (fy_code) REFERENCES system.financial_year(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX rrr_fy_code_fk165_ind ON administrative.rrr (fy_code);

ALTER TABLE administrative.required_relationship_baunit ADD CONSTRAINT required_relationship_baunit_transaction_id_fk166 
            FOREIGN KEY (transaction_id) REFERENCES transaction.transaction(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX required_relationship_baunit_transaction_id_fk166_ind ON administrative.required_relationship_baunit (transaction_id);

ALTER TABLE application.application ADD CONSTRAINT application_fy_code_fk167 
            FOREIGN KEY (fy_code) REFERENCES system.financial_year(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX application_fy_code_fk167_ind ON application.application (fy_code);

ALTER TABLE system.vdc_appuser ADD CONSTRAINT vdc_appuser_vdc_code_fk168 
            FOREIGN KEY (vdc_code) REFERENCES address.vdc(code) ON UPDATE CASCADE ON DELETE Cascade;
CREATE INDEX vdc_appuser_vdc_code_fk168_ind ON system.vdc_appuser (vdc_code);

ALTER TABLE system.vdc_appuser ADD CONSTRAINT vdc_appuser_appuser_id_fk169 
            FOREIGN KEY (appuser_id) REFERENCES system.appuser(id) ON UPDATE CASCADE ON DELETE Cascade;
CREATE INDEX vdc_appuser_appuser_id_fk169_ind ON system.vdc_appuser (appuser_id);

ALTER TABLE party.party ADD CONSTRAINT party_grandfather_type_code_fk170 
            FOREIGN KEY (grandfather_type_code) REFERENCES party.grandfather_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_grandfather_type_code_fk170_ind ON party.party (grandfather_type_code);

ALTER TABLE party.party ADD CONSTRAINT party_father_type_code_fk171 
            FOREIGN KEY (father_type_code) REFERENCES party.father_type(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX party_father_type_code_fk171_ind ON party.party (father_type_code);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_dataset_id_fk172 
            FOREIGN KEY (dataset_id) REFERENCES cadastre.dataset(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_dataset_id_fk172_ind ON cadastre.cadastre_object (dataset_id);

ALTER TABLE cadastre.dataset ADD CONSTRAINT dataset_office_code_fk173 
            FOREIGN KEY (office_code) REFERENCES system.office(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX dataset_office_code_fk173_ind ON cadastre.dataset (office_code);

ALTER TABLE cadastre.dataset ADD CONSTRAINT dataset_vdc_code_fk174 
            FOREIGN KEY (vdc_code) REFERENCES address.vdc(code) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX dataset_vdc_code_fk174_ind ON cadastre.dataset (vdc_code);

ALTER TABLE cadastre.cadastre_object ADD CONSTRAINT cadastre_object_address_id_fk175 
            FOREIGN KEY (address_id) REFERENCES address.address(id) ON UPDATE CASCADE ON DELETE RESTRICT;
CREATE INDEX cadastre_object_address_id_fk175_ind ON cadastre.cadastre_object (address_id);

ALTER TABLE party.party_category_for_party ADD CONSTRAINT party_category_for_party_party_categorycode_fk176 
            FOREIGN KEY (party_categorycode) REFERENCES party.party_category(code) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX party_category_for_party_party_categorycode_fk176_ind ON party.party_category_for_party (party_categorycode);

ALTER TABLE party.party_category_for_party ADD CONSTRAINT party_category_for_party_partyid_fk177 
            FOREIGN KEY (partyid) REFERENCES party.party(id) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX party_category_for_party_partyid_fk177_ind ON party.party_category_for_party (partyid);
--Generate triggers for tables --
-- triggers for table source.source -- 

 

CREATE OR REPLACE FUNCTION source.f_for_tbl_source_trg_change_of_status() RETURNS TRIGGER 
AS $$
begin
  if old.status_code is not null and old.status_code = 'pending' and new.status_code in ( 'current', 'historic') then
      update source.source set 
      status_code= 'previous', change_user=new.change_user
      where la_nr= new.la_nr and status_code = 'current';
  end if;
  return new;
end;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_change_of_status ON source.source CASCADE;
CREATE TRIGGER trg_change_of_status before update
   ON source.source FOR EACH ROW
   EXECUTE PROCEDURE source.f_for_tbl_source_trg_change_of_status();
    
-- triggers for table administrative.ba_unit -- 

 

CREATE OR REPLACE FUNCTION administrative.f_for_tbl_ba_unit_trg_check_cadastre_object() RETURNS TRIGGER 
AS $$
DECLARE cadastre_object record;
BEGIN

if new.cadastre_object_id is not null then
  select id, name_firstpart, name_lastpart into cadastre_object from cadastre.cadastre_object where id = new.cadastre_object_id;
  if cadastre_object.id is not null then
    if new.name_firstpart != cadastre_object.name_firstpart or new.name_lastpart != cadastre_object.name_lastpart then
      RAISE EXCEPTION 'Cadastre object name first/last part doesn''t match name first/last part on the BaUnit';
    end if;
  end if;
end if;

RETURN NEW;

END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_check_cadastre_object ON administrative.ba_unit CASCADE;
CREATE TRIGGER trg_check_cadastre_object before insert or update
   ON administrative.ba_unit FOR EACH ROW
   EXECUTE PROCEDURE administrative.f_for_tbl_ba_unit_trg_check_cadastre_object();
    
-- triggers for table administrative.rrr -- 

 

CREATE OR REPLACE FUNCTION administrative.f_for_tbl_rrr_trg_check_ownership_rrr() RETURNS TRIGGER 
AS $$
DECLARE group_type varchar;
BEGIN

if new.loc_id is not null then
  select rrr_group_type_code into group_type from administrative.rrr_type where code = new.type_code;
  if group_type != 'ownership' then
    RAISE EXCEPTION 'Only RRRs of ownership type can have LOC_ID';
  end if;
end if;

if new.loc_id is null then
  select rrr_group_type_code into group_type from administrative.rrr_type where code = new.type_code;
  if group_type = 'ownership' then
    RAISE EXCEPTION 'RRR of ownership type must have LOC_ID';
  end if;
end if;

RETURN NEW;

END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_check_ownership_rrr ON administrative.rrr CASCADE;
CREATE TRIGGER trg_check_ownership_rrr before insert or update
   ON administrative.rrr FOR EACH ROW
   EXECUTE PROCEDURE administrative.f_for_tbl_rrr_trg_check_ownership_rrr();
    

CREATE OR REPLACE FUNCTION administrative.f_for_tbl_rrr_trg_check_loc_id_unique_per_ba_unit() RETURNS TRIGGER 
AS $$
DECLARE cnt int;
BEGIN

if new.loc_id is not null then
  if new.status_code='pending' then
    select count(1) into cnt from administrative.rrr where id != new.id and ba_unit_id = new.ba_unit_id and status_code = 'pending' and 
loc_id is not null;
    if cnt>0 then
      RAISE EXCEPTION 'There should be only 1 pending RRR with LOC_ID';
    end if;
  end if;
  if new.status_code='current' then
    select count(1) into cnt from administrative.rrr where id != new.id and ba_unit_id = new.ba_unit_id and status_code = 'current' and 
loc_id is not null;
    if cnt>0 then
      RAISE EXCEPTION 'There should be only 1 current RRR with LOC_ID';
    end if;
  end if;
end if;

RETURN NEW;

END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_check_loc_id_unique_per_ba_unit ON administrative.rrr CASCADE;
CREATE TRIGGER trg_check_loc_id_unique_per_ba_unit before insert or update
   ON administrative.rrr FOR EACH ROW
   EXECUTE PROCEDURE administrative.f_for_tbl_rrr_trg_check_loc_id_unique_per_ba_unit();
    

CREATE OR REPLACE FUNCTION administrative.f_for_tbl_rrr_trg_change_from_pending() RETURNS TRIGGER 
AS $$
begin
  if old.status_code = 'pending' and new.status_code in ( 'current', 'historic') then
    update administrative.rrr set 
      status_code= 'previous', change_user=new.change_user
    where ba_unit_id= new.ba_unit_id and nr= new.nr and status_code = 'current';
  end if;
  return new;
end;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_change_from_pending ON administrative.rrr CASCADE;
CREATE TRIGGER trg_change_from_pending before update
   ON administrative.rrr FOR EACH ROW
   EXECUTE PROCEDURE administrative.f_for_tbl_rrr_trg_change_from_pending();
    
-- triggers for table cadastre.cadastre_object -- 

 

CREATE OR REPLACE FUNCTION cadastre.f_for_tbl_cadastre_object_trg_remove() RETURNS TRIGGER 
AS $$
BEGIN
  delete from cadastre.spatial_unit where id=old.id;
  return old;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_remove ON cadastre.cadastre_object CASCADE;
CREATE TRIGGER trg_remove before delete
   ON cadastre.cadastre_object FOR EACH ROW
   EXECUTE PROCEDURE cadastre.f_for_tbl_cadastre_object_trg_remove();
    

CREATE OR REPLACE FUNCTION cadastre.f_for_tbl_cadastre_object_trg_new() RETURNS TRIGGER 
AS $$
BEGIN
  if (select count(*)=0 from cadastre.spatial_unit where id=new.id) then
    insert into cadastre.spatial_unit(id, rowidentifier, change_user) 
    values(new.id, new.rowidentifier,new.change_user);
  end if;
  return new;
END;

$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_new ON cadastre.cadastre_object CASCADE;
CREATE TRIGGER trg_new before insert
   ON cadastre.cadastre_object FOR EACH ROW
   EXECUTE PROCEDURE cadastre.f_for_tbl_cadastre_object_trg_new();
    

CREATE OR REPLACE FUNCTION cadastre.f_for_tbl_cadastre_object_trg_geommodify() RETURNS TRIGGER 
AS $$
declare
  geom_is_modified boolean;
  rec record;
  rec_snap record;
  snapping_tolerance float;
begin
  snapping_tolerance = coalesce(system.get_setting('map-tolerance')::double precision, 0.01);
  geom_is_modified = (tg_op = 'INSERT' and new.geom_polygon is not null);
  if tg_op= 'UPDATE' and new.geom_polygon is not null then
    geom_is_modified = not st_equals(new.geom_polygon, old.geom_polygon);
  end if;
  if not geom_is_modified then
    return new;
  end if;
  for rec in select co.id, co.geom_polygon 
                 from cadastre.cadastre_object co 
                 where  co.id != new.id 
                     and co.geom_polygon is not null 
                     and st_dwithin(new.geom_polygon, co.geom_polygon, snapping_tolerance)
  loop
    select * into rec_snap 
        from snap_geometry_to_geometry(new.geom_polygon, rec.geom_polygon, snapping_tolerance, false);
      new.geom_polygon = rec_snap.geom_to_snap;
  end loop;
  return new;
end;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_geommodify ON cadastre.cadastre_object CASCADE;
CREATE TRIGGER trg_geommodify before insert or update
   ON cadastre.cadastre_object FOR EACH ROW
   EXECUTE PROCEDURE cadastre.f_for_tbl_cadastre_object_trg_geommodify();
    
-- triggers for table system.financial_year -- 

 

CREATE OR REPLACE FUNCTION system.f_for_tbl_financial_year_trg_update_current() RETURNS TRIGGER 
AS $$
BEGIN
    IF ((TG_OP = 'UPDATE' OR TG_OP = 'INSERT') AND NEW.current='t') THEN
        UPDATE "system".financial_year SET "current"='f' where "current"='t';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_update_current ON system.financial_year CASCADE;
CREATE TRIGGER trg_update_current before insert or update
   ON system.financial_year FOR EACH ROW
   EXECUTE PROCEDURE system.f_for_tbl_financial_year_trg_update_current();
    

--Extra modifications added to the script that cannot be generated --

CREATE INDEX application_historic_id_ind ON application.application_historic (id);

CREATE INDEX service_application_historic_ind ON application.service_historic (application_id);

DROP SEQUENCE IF EXISTS application.application_nr_seq;
CREATE SEQUENCE application.application_nr_seq
INCREMENT 1
MINVALUE 1
MAXVALUE 9999
START 1
CACHE 1
CYCLE;
COMMENT ON SEQUENCE application.application_nr_seq IS 'Allocates numbers 1 to 9999 for application number';

DROP SEQUENCE IF EXISTS source.source_la_nr_seq;
CREATE SEQUENCE source.source_la_nr_seq
INCREMENT 1
MINVALUE 1
MAXVALUE 999999999
START 1
CACHE 1
CYCLE;
COMMENT ON SEQUENCE source.source_la_nr_seq IS 'Allocates numbers 1 to 999999999 for source la number';

DROP SEQUENCE IF EXISTS document.document_nr_seq;

CREATE SEQUENCE document.document_nr_seq
INCREMENT 1
MINVALUE 1
MAXVALUE 99999999
START 1
CACHE 1
CYCLE;
COMMENT ON SEQUENCE "document".document_nr_seq IS 'Allocates numbers 1 to 99999999 for document number';

DROP SEQUENCE IF EXISTS administrative.rrr_nr_seq;

CREATE SEQUENCE administrative.rrr_nr_seq
INCREMENT 1
MINVALUE 1
MAXVALUE 9999
START 1
CACHE 1
CYCLE;
COMMENT ON SEQUENCE administrative.rrr_nr_seq IS 'Allocates numbers 1 to 9999 for rrr number';

DROP SEQUENCE IF EXISTS administrative.notation_reference_nr_seq;
CREATE SEQUENCE administrative.notation_reference_nr_seq
INCREMENT 1
MINVALUE 1
MAXVALUE 9999
START 1
CACHE 1
CYCLE;
COMMENT ON SEQUENCE administrative.notation_reference_nr_seq IS 'Allocates numbers 1 to 9999 for reference number for notation';

CREATE OR REPLACE FUNCTION system.setPassword(usrName character varying, pass character varying) 
RETURNS INT AS
$BODY$
DECLARE
  result int;
BEGIN
  update system.appuser set passwd = pass where username=usrName;
  GET DIAGNOSTICS result = ROW_COUNT;
  return result;
END;
$BODY$
  LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION party.is_rightholder(id character varying)
  RETURNS boolean AS
$BODY$
BEGIN
  return (SELECT (CASE (SELECT COUNT(1) FROM administrative.party_for_rrr ap WHERE ap.party_id = id) WHEN 0 THEN false ELSE true END));
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;

create or replace function system.get_setting(setting_name varchar) returns varchar
as
$BODY$
begin
  return (select vl from system.setting where name= setting_name);
end;
$BODY$
LANGUAGE plpgsql;

CREATE SEQUENCE administrative.ba_unit_first_name_part_seq
  INCREMENT 1
  MINVALUE 1
  MAXVALUE 9999
  START 1
  CACHE 1
  CYCLE;
COMMENT ON SEQUENCE administrative.ba_unit_first_name_part_seq IS 'Allocates numbers 1 to 9999 for ba unit first name part';

CREATE SEQUENCE administrative.ba_unit_last_name_part_seq
  INCREMENT 1
  MINVALUE 1
  MAXVALUE 9999
  START 1
  CACHE 1
  CYCLE;
COMMENT ON SEQUENCE administrative.ba_unit_last_name_part_seq IS 'Allocates numbers 1 to 9999 for ba unit last name part';

CREATE OR REPLACE FUNCTION administrative.get_ba_unit_pending_action(baunit_id character varying)
  RETURNS character varying AS
$BODY$
BEGIN

  return (SELECT 'cancel'
  FROM administrative.ba_unit_target bt INNER JOIN transaction.transaction t ON bt.transaction_id = t.id
  WHERE bt.ba_unit_id = baunit_id AND t.status_code = 'pending'
  LIMIT 1);

END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;

CREATE OR REPLACE FUNCTION application.getlodgement(fromdate character varying, todate character varying)
  RETURNS SETOF record AS
$BODY$
DECLARE 

    resultType  varchar;
    resultGroup varchar;
    resultTotal integer :=0 ;
    resultTotalPerc decimal:=0 ;
    resultDailyAvg  decimal:=0 ;
    resultTotalReq integer:=0 ;
    resultReqPerc  decimal:=0 ;
    TotalTot integer:=0 ;
    appoDiff integer:=0 ;

    
    rec     record;
    sqlSt varchar;
    lodgementFound boolean;
    recToReturn record;

    
BEGIN  
    appoDiff := (to_date(''|| toDate || '','yyyy-mm-dd') - to_date(''|| fromDate || '','yyyy-mm-dd'));
     if  appoDiff= 0 then 
            appoDiff:= 1;
     end if; 
    sqlSt:= '';
    
    sqlSt:= 'select   1 as order,
         get_translation(application.request_type.display_value, null) as type,
         application.request_type.request_category_code as group,
         count(application.service_historic.id) as total,
         round((CAST(count(application.service_historic.id) as decimal)
         /
         '||appoDiff||'
         ),2) as dailyaverage
from     application.service_historic,
         application.request_type
where    application.service_historic.request_type_code = application.request_type.code
         and
         application.service_historic.lodging_datetime between to_date('''|| fromDate || ''',''yyyy-mm-dd'')  and to_date('''|| toDate || ''',''yyyy-mm-dd'')
         and application.service_historic.action_code=''lodge''
         and application.service_historic.application_id in
	      (select distinct(application.application_historic.id)
	       from application.application_historic)
group by application.service_historic.request_type_code, application.request_type.display_value,
         application.request_type.request_category_code
union
select   2 as order,
         ''Total'' as type,
         ''All'' as group,
         count(application.service_historic.id) as total,
         round((CAST(count(application.service_historic.id) as decimal)
         /
         '||appoDiff||'
         ),2) as dailyaverage
from     application.service_historic,
         application.request_type
where    application.service_historic.request_type_code = application.request_type.code
         and
         application.service_historic.lodging_datetime between to_date('''|| fromDate || ''',''yyyy-mm-dd'')  and to_date('''|| toDate || ''',''yyyy-mm-dd'')
         and application.service_historic.application_id in
	      (select distinct(application.application_historic.id)
	       from application.application_historic)
order by 1,3,2;
';




  

    --raise exception '%',sqlSt;
    lodgementFound = false;
    -- Loop through results
         select   
         count(application.service_historic.id)
         into TotalTot
from     application.service_historic,
         application.request_type
where    application.service_historic.request_type_code = application.request_type.code
         and
         application.service_historic.lodging_datetime between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd')
         and application.service_historic.application_id in
	      (select distinct(application.application_historic.id)
	       from application.application_historic);

    
    FOR rec in EXECUTE sqlSt loop
            resultType:= rec.type;
	    resultGroup:= rec.group;
	    resultTotal:= rec.total;
	    if  TotalTot= 0 then 
               TotalTot:= 1;
            end if; 
	    resultTotalPerc:= round((CAST(rec.total as decimal)*100/TotalTot),2);
	    resultDailyAvg:= rec.dailyaverage;
            resultTotalReq:= 0;

           

            if rec.type = 'Total' then
                 select   count(application.service_historic.id) into resultTotalReq
		from application.service_historic
		where application.service_historic.action_code='lodge'
                      and
                      application.service_historic.lodging_datetime between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd')
                      and application.service_historic.application_id in
		      (select application.application_historic.id
		       from application.application_historic
		       where application.application_historic.action_code='requisition');
            else
                  select  count(application.service_historic.id) into resultTotalReq
		from application.service_historic
		where application.service_historic.action_code='lodge'
                      and
                      application.service_historic.lodging_datetime between to_date(''|| fromDate || '','yyyy-mm-dd')  and to_date(''|| toDate || '','yyyy-mm-dd')
                      and application.service_historic.application_id in
		      (select application.application_historic.id
		       from application.application_historic
		       where application.application_historic.action_code='requisition'
		      )   
		and   application.service_historic.request_type_code = rec.type     
		group by application.service_historic.request_type_code;
            end if;

             if  rec.total= 0 then 
               appoDiff:= 1;
             else
               appoDiff:= rec.total;
             end if; 
            resultReqPerc:= round((CAST(resultTotalReq as decimal)*100/appoDiff),2);

            if resultType is null then
              resultType :=0 ;
            end if;
	    if resultTotal is null then
              resultTotal  :=0 ;
            end if;  
	    if resultTotalPerc is null then
	         resultTotalPerc  :=0 ;
            end if;  
	    if resultDailyAvg is null then
	        resultDailyAvg  :=0 ;
            end if;  
	    if resultTotalReq is null then
	        resultTotalReq  :=0 ;
            end if;  
	    if resultReqPerc is null then
	        resultReqPerc  :=0 ;
            end if;  

	    if TotalTot is null then
	       TotalTot  :=0 ;
            end if;  
	  
          select into recToReturn resultType::varchar, resultGroup::varchar, resultTotal::integer, resultTotalPerc::decimal,resultDailyAvg::decimal,resultTotalReq::integer,resultReqPerc::decimal;
          return next recToReturn;
          lodgementFound = true;
    end loop;
   
    if (not lodgementFound) then
        RAISE EXCEPTION 'no_lodgement_found';
    end if;
    return;
END;
$BODY$
  LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION application.getlodgetiming(fromdate date, todate date)
  RETURNS SETOF record AS
$BODY$
DECLARE 
    timeDiff integer:=0 ;
BEGIN
timeDiff := toDate-fromDate;
if timeDiff<=0 then 
    timeDiff:= 1;
end if; 

return query
select 'Lodged not completed'::varchar as resultCode, count(1)::integer as resultTotal, (round(count(1)::numeric/timeDiff,1))::float as resultDailyAvg, 1 as ord 
from application.application
where lodging_datetime between fromdate and todate and status_code = 'lodged'
union
select 'Registered' as resultCode, count(1)::integer as resultTotal, (round(count(1)::numeric/timeDiff,1))::float as resultDailyAvg, 2 as ord 
from application.application
where lodging_datetime between fromdate and todate
union
select 'Rejected' as resultCode, count(1)::integer as resultTotal, (round(count(1)::numeric/timeDiff,1))::float as resultDailyAvg, 3 as ord 
from application.application
where lodging_datetime between fromdate and todate and status_code = 'annuled'
union
select 'On Requisition' as resultCode, count(1)::integer as resultTotal, (round(count(1)::numeric/timeDiff,1))::float as resultDailyAvg, 4 as ord 
from application.application
where lodging_datetime between fromdate and todate and status_code = 'requisitioned'
union
select 'Withdrawn' as resultCode, count(distinct id)::integer as resultTotal, (round(count(distinct id)::numeric/timeDiff,1))::float as resultDailyAvg, 5 as ord 
from application.application_historic
where change_time between fromdate and todate and action_code = 'withdraw'
order by ord;

END;
$BODY$
  LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION administrative.get_loc_rrrs(IN text, IN text)
  RETURNS TABLE(loc_id character varying, type_code character varying, owner_type_code character varying, ownership_type_code character varying, status_code character varying) AS
$BODY$ 
BEGIN
	RETURN QUERY SELECT DISTINCT r.loc_id, r.type_code, r.owner_type_code, r.ownership_type_code, r.status_code
	FROM administrative.rrr r
	WHERE r.is_terminating = 'f' AND r.loc_id = $1 AND r.office_code = $2 AND (r.status_code='pending' OR r.status_code='current');
END;
$BODY$
  LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION administrative.get_loc_party_ids(_loc_id text, _status text) 
RETURNS TABLE(id character varying(40))
AS $$ 
BEGIN
	RETURN QUERY SELECT DISTINCT p.party_id
	FROM administrative.rrr r INNER JOIN administrative.party_for_rrr p ON r.id = p.rrr_id
	WHERE r.is_terminating = 'f' AND r.loc_id = _loc_id AND r.status_code=_status;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION party.get_party_name(party_id character varying)
  RETURNS character varying AS
$BODY$
BEGIN
  IF(party_id IS NOT NULL) THEN
    return (SELECT COALESCE("name", '') + (CASE COALESCE(last_name, '') WHEN '' THEN '' ELSE ' ' + COALESCE(last_name, '') END) as party_name FROM party.party WHERE id = party_id);
  ELSE
    return '';
  END IF;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;

CREATE OR REPLACE FUNCTION administrative.get_ba_unit_moth_loc(IN text, IN boolean)
  RETURNS TABLE(ba_ubit_id character varying, loc_id character varying, moth_id character varying, page_no character varying, moth_no character varying) AS
$BODY$ 
BEGIN

IF $2 = 't' AND (SELECT COUNT(1) FROM administrative.rrr r inner join (administrative.loc l INNER JOIN administrative.moth m on l.moth_id=m.id) on r.loc_id=l.id
WHERE r.status_code='current' AND r.ba_unit_id = $1)<1 THEN
  RETURN QUERY SELECT DISTINCT r.ba_unit_id, l.id, m.id, l.pana_no, m.mothluj_no 
  FROM administrative.rrr r inner join (administrative.loc l INNER JOIN administrative.moth m on l.moth_id=m.id) on r.loc_id=l.id
  WHERE r.status_code='pending' AND r.ba_unit_id = $1;
ELSE
  RETURN QUERY SELECT DISTINCT r.ba_unit_id, l.id, m.id, l.pana_no, m.mothluj_no 
  FROM administrative.rrr r inner join (administrative.loc l INNER JOIN administrative.moth m on l.moth_id=m.id) on r.loc_id=l.id
  WHERE r.status_code='current' AND r.ba_unit_id = $1;
END IF;

END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;

CREATE OR REPLACE FUNCTION application.f_get_application_status_change_date(appId text)
  RETURNS timestamp without time zone AS
$BODY$
DECLARE result timestamp without time zone;
BEGIN
      return (select max(status_change_time)
              from 
              (select id, status_code, change_time as status_change_time, rowversion 
              from application.application 
              where id=$1
              union 
              select id, status_code, change_time as status_change_time, rowversion
              from application.application_historic
              where id=$1) app_all LEFT JOIN application.application_historic ah on app_all.id = ah.id and ah.rowversion = app_all.rowversion - 1
              where ah.status_code != app_all.status_code or ah.status_code is null
              );
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;

insert into system.approle_appgroup (approle_code, appgroup_id)
SELECT r.code, 'super-group-id' FROM system.approle r 
where r.code not in (select approle_code from system.approle_appgroup g where appgroup_id = 'super-group-id');

-------View cadastre.survey_control ---------
DROP VIEW IF EXISTS cadastre.survey_control CASCADE;
CREATE VIEW cadastre.survey_control AS SELECT su.id, su.label, su.geom
FROM cadastre.level l, cadastre.spatial_unit su 
WHERE l.id = su.level_id AND l.name = 'Survey Control';;

-------View cadastre.road ---------
DROP VIEW IF EXISTS cadastre.road CASCADE;
CREATE VIEW cadastre.road AS SELECT su.id, su.label, su.geom
FROM cadastre.level l, cadastre.spatial_unit su 
WHERE l.id= su.level_id AND l.name = 'Roads';;

-------View cadastre.place_name ---------
DROP VIEW IF EXISTS cadastre.place_name CASCADE;
CREATE VIEW cadastre.place_name AS SELECT su.id, su.label, su.geom
FROM cadastre.level l, cadastre.spatial_unit su 
WHERE l.id = su.level_id AND l.name = 'Place Names';;

-------View system.user_roles ---------
DROP VIEW IF EXISTS system.user_roles CASCADE;
CREATE VIEW system.user_roles AS SELECT u.username, rg.approle_code as rolename
   FROM system.appuser u
   JOIN system.appuser_appgroup ug ON (u.id = ug.appuser_id and u.active)
   JOIN system.approle_appgroup rg ON ug.appgroup_id = rg.appgroup_id
;

-------View application.application_log ---------
DROP VIEW IF EXISTS application.application_log CASCADE;
CREATE VIEW application.application_log AS select uuid_generate_v1()::varchar as id, id as application_id, action_code as action_type, '' as service_order, null as service_type, change_time, 
(select first_name || ' ' || last_name from system.appuser where id = application.change_user) as user_fullname, action_notes
from application.application
union
select uuid_generate_v1()::varchar as id, id as application_id, action_code, '' as service_order, null as service_type, change_time, 
(select first_name || ' ' || last_name from system.appuser where id = application_historic.change_user) as user_fullname, action_notes
from application.application_historic 
union
select uuid_generate_v1()::varchar as id, application_id, status_code, service_order::varchar, request_type_code, change_time, 
(select first_name || ' ' || last_name from system.appuser where id = service.change_user) as user_fullname, action_notes
from application.service
union 
select uuid_generate_v1()::varchar as id, application_id, status_code, service_order::varchar, request_type_code, change_time, 
(select first_name || ' ' || last_name from system.appuser where id = service_historic.change_user) as user_fullname, action_notes
from application.service_historic;;

-------View system.br_current ---------
DROP VIEW IF EXISTS system.br_current CASCADE;
CREATE VIEW system.br_current AS select b.id, b.technical_type_code, b.feedback, bd.body
from system.br b inner join system.br_definition bd on b.id= bd.br_id
where now() between bd.active_from and bd.active_until;

-------View system.br_report ---------
DROP VIEW IF EXISTS system.br_report CASCADE;
CREATE VIEW system.br_report AS SELECT  b.id, b.technical_type_code, b.feedback, b.description,
CASE WHEN target_code = 'application' THEN bv.target_application_moment
WHEN target_code = 'service' THEN bv.target_service_moment
ELSE bv.target_reg_moment
END AS moment_code,
bd.body, bv.severity_code, bv.target_code, bv.target_request_type_code, 
bv.target_rrr_type_code, bv.order_of_execution
FROM system.br b
  LEFT OUTER JOIN system.br_validation bv  ON b.id = bv.br_id
  JOIN system.br_definition bd ON b.id = bd.br_id
WHERE now() >= bd.active_from AND now() <= bd.active_until
order by b.id;


-- Scan tables and views for geometry columns                 and populate geometry_columns table

SELECT Populate_Geometry_Columns();

--central meridian at 84 degree.
--first delete the srid.
delete from public.spatial_ref_sys where srid=97261;
--insert new data.
INSERT into public.spatial_ref_sys (srid, auth_name, auth_srid, proj4text, srtext) 
values 
( 97261, 
'sr-org', 
7261, 
'+proj=tmerc +lat_0=0 +lon_0=84 +k=0.9999 +x_0=500000 +y_0=0 +a=6377276.345 +b=6356075.41314024 +units=m +no_defs ',
'PROJCS["Nepal_Central",GEOGCS["nepal_geo",DATUM["D_Everest_Bangladesh",SPHEROID["Everest_Adjustment_1937",6377276.345,300.8017]],PRIMEM["Greenwich",0.0],
UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",500000.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",84.0],PARAMETER["Scale_Factor",0.9999],
PARAMETER["Latitude_Of_Origin",0.0],UNIT["Meter",1.0]]');

--central meridian at 81 degree.
--first delete the srid.
delete from public.spatial_ref_sys where srid=97260;
--insert new data.
INSERT into public.spatial_ref_sys (srid, auth_name, auth_srid, proj4text, srtext) 
values 
( 97260, 
'sr-org', 
7260, 
'+proj=tmerc +lat_0=0 +lon_0=81 +k=0.9999 +x_0=500000 +y_0=0 +a=6377276.345 +b=6356075.41314024 +units=m +no_defs ',
'PROJCS["Nepal_Central",GEOGCS["nepal_geo",DATUM["D_Everest_Bangladesh",SPHEROID["Everest_Adjustment_1937",6377276.345,300.8017]],PRIMEM["Greenwich",0.0],
UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",500000.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",81.0],PARAMETER["Scale_Factor",0.9999],
PARAMETER["Latitude_Of_Origin",0.0],UNIT["Meter",1.0]]');

--central meridian at 87 degree.
--first delete the srid.
delete from public.spatial_ref_sys where srid=97262;
--insert new data.
INSERT into public.spatial_ref_sys (srid, auth_name, auth_srid, proj4text, srtext) 
values 
( 97262, 
'sr-org', 
7262, 
'+proj=tmerc +lat_0=0 +lon_0=87 +k=0.9999 +x_0=500000 +y_0=0 +a=6377276.345 +b=6356075.41314024 +units=m +no_defs ',
'PROJCS["Nepal_Central",GEOGCS["nepal_geo",DATUM["D_Everest_Bangladesh",SPHEROID["Everest_Adjustment_1937",6377276.345,300.8017]],PRIMEM["Greenwich",0.0],
UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",500000.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",87.0],PARAMETER["Scale_Factor",0.9999],
PARAMETER["Latitude_Of_Origin",0.0],UNIT["Meter",1.0]]');
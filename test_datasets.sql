INSERT INTO cadastre.dataset (id, name, srid, office_code, vdc_code) VALUES ('ds1', 'Dataset1', 97261, '101', '43055')
INSERT INTO cadastre.dataset (id, name, srid, office_code, vdc_code) VALUES ('ds2', 'Dataset2', 97261, '101', '27009')

UPDATE cadastre.cadastre_object SET dataset_id = 'ds1' WHERE id IN (SELECT id FROM cadastre.cadastre_object LIMIT (SELECT COUNT(1)/2 FROM cadastre.cadastre_object))
UPDATE cadastre.cadastre_object SET dataset_id = 'ds2' WHERE dataset_id IS NULL
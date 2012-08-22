delete from system.financial_year;
insert into system.financial_year (code, display_value, status, "current", start_date, end_date) values ('y1', '2012', 'c', 't', '10-10-2011', '10-10-2012');
delete from administrative.moth;
insert into administrative.moth (id, fy_code, mothluj_no, vdc_code, moth_luj, office_code) values ('123', 'y1', '11122', '27009', 'M', '7-25-003-001');
insert into administrative.moth (id, fy_code, mothluj_no, vdc_code, moth_luj, office_code) values ('1234', 'y1', '23422', '27009', 'M', '7-25-003-001');
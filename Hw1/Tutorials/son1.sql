create extension if not exists "uuid-ossp"

create table locations (
	id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
	point geometry(Point,4326),
	time int
);

ALTER TABLE locations
ADD COLUMN route_id INT;

create index locations_point_idx ON locations using GIST(point);

do $$
declare
    _max_move float := 1 / 110.0; -- 1km
    _start_loc geometry := ST_SetSRID(ST_MakePoint(28.8884187, 41.0275262), 4326); -- başlangıç noktası
    _end_loc geometry := ST_SetSRID(ST_MakePoint(28.8107647, 41.0479372), 4326); -- bitiş noktası (başlangıç ile aynı)
    _current_loc geometry;
    _new_loc geometry;
    _rota_no integer := 1;
	_time integer := 0 ;
 begin
    delete from locations;
    for _rota_no in 1..10 loop
	_time := 0 ;
        -- Başlangıç noktasını ekle
        insert into locations (point, time, route_id) values (_start_loc, _time, _rota_no);
        _current_loc := _start_loc;
		_time := _time + 1;
        
        -- Hedef noktasına ulaşana kadar döngü
        loop
            -- Rastgele nokta oluştur
			_new_loc := ST_SetSRID(ST_MakePoint(
			  ST_X(_current_loc) + random() * _max_move - _max_move / 2,
			  ST_Y(_current_loc) + random() * _max_move - _max_move / 2
			), 4326);

			-- Koşulu kontrol et
			if ST_Distance(_new_loc, _end_loc) < ST_Distance(_current_loc, _end_loc) then
			  -- Yeni noktayı ekle
			  insert into locations (point, time, route_id) values (_new_loc, _time, _rota_no);
			  _time := _time + 1;
			  -- Mevcut noktayı güncelle
			  _current_loc := _new_loc;

			  -- Hedef noktasına ulaşılmışsa döngüden çık
			  if ST_Distance(_current_loc, _end_loc) <= _max_move then
				EXIT;
			  end if;
			end if;
        end loop;
        
        -- Bitiş noktasını ekle
        insert into locations (point, time, route_id) values (_end_loc, _time, _rota_no);
    end loop;
end;
$$

-- rota viewını oluşturan sorgu
CREATE OR REPLACE VIEW route AS (
    WITH data_points AS (
        SELECT route_id as id, point
        FROM locations
        ORDER BY route_id, time
    )
    SELECT id, ST_MakeLine(point) AS line
    FROM data_points
    GROUP BY id
);

select ST_AsGeoJSON(line)
from route



-- TÜM YARIŞMACILARIN SIRA NOSUNU YARIŞMACI NUMARASINI VE BİTİRME SÜRESİNİ VİEW OLARAK KAYDEDEN SORGU

CREATE OR REPLACE VIEW race_results_view AS
SELECT 
  ROW_NUMBER() OVER (ORDER BY MAX(time)::double precision) AS sira_no,
  route_id AS yarismaci_no,
  MAX(time)::double precision AS bitirme_suresi
FROM locations
GROUP BY route_id
ORDER BY bitirme_suresi ASC;

select *
from race_results_view



-- YÜKSELME VE ALÇALMA SAYISI
CREATE OR REPLACE VIEW elevation_changes_view AS
WITH data_points AS (
    SELECT 
        route_id,
        l.time,
        ST_Value(e.rast, ST_Transform(l.point, 4326)) AS elevation,
        RANK() OVER (PARTITION BY route_id ORDER BY l.time) AS ordinal
    FROM 
        locations l
    INNER JOIN 
        deneme e ON ST_Intersects(ST_ConvexHull(e.rast), ST_Transform(l.point, 4326))
), 
elevation_deltas AS (
    SELECT 
        dp1.route_id,
        dp1.ordinal,
        dp2.elevation - dp1.elevation AS delta,
        CASE WHEN dp1.elevation < dp2.elevation THEN 'ascent' ELSE 'descent' END AS direction
    FROM 
        data_points dp1
    INNER JOIN 
        data_points dp2 ON dp2.route_id = dp1.route_id AND dp2.ordinal = dp1.ordinal + 1
)
SELECT 
    ed.route_id AS rota_id,
    SUM(CASE WHEN ed.direction = 'ascent' THEN ed.delta ELSE 0 END) AS total_ascent,
    SUM(CASE WHEN ed.direction = 'descent' THEN ed.delta ELSE 0 END) AS total_descent
FROM 
    elevation_deltas ed
GROUP BY 
    ed.route_id;

select * 
from elevation_changes_view



-- HER YARIŞMACININ TOPLAMDA ALDIĞI YOLU BULAN FONKSİYON
CREATE OR REPLACE VIEW race_distances_view AS
WITH data_points AS (
    SELECT 
        route_id,
        time,
        point,
        RANK() OVER (PARTITION BY route_id ORDER BY time) AS ordinal
    FROM 
        locations
)
, distances AS (
    SELECT 
        dp1.route_id as route_id,
        ST_DistanceSphere(dp1.point, dp2.point) AS distance, 
        dp1.time
    FROM 
        data_points dp1
    INNER JOIN 
        data_points dp2 ON dp2.ordinal = dp1.ordinal + 1 AND dp1.route_id = dp2.route_id
)
SELECT 
    distances.route_id as yarismaci_no,
    CAST(SUM(distance)/1000.0 AS DECIMAL(10,3)) AS alinan_yol, 
    CAST((max(time) - min(time))/3600.0 AS DECIMAL(10,3)) AS toplam_süre, 
    CAST(sum(distance)/1000.0 / ((max(time) - min(time))/3600.0) AS DECIMAL(10,1)) as ort_hiz,
    CAST(SUM(distance) / 1000.0 * 30 AS DECIMAL(10,1)) AS toplam_kalori
FROM 
    distances
GROUP BY 
    distances.route_id;
	
select *
from race_distances_view



-- BELLİ BİR ALANDA HESAP
28.848918,41.031795, 28.847273,41.023524, 28.857598,41.017113, 28.868744,41.030761, 28.848918,41.031795

-- CHATGPT
delete from locations;
DO $$
DECLARE
    _start_loc geometry;
    _end_loc geometry;
    _num_routes int := 5; -- Toplam rota sayısı
    _num_points int := 100; -- Her rota için oluşturulacak nokta sayısı
    _current_route int;
    _current_point int;
    _current_loc geometry;
    _step_size float;
    _distance float;
    _azimuth float;
    _max_deviation float := 0.9; -- Maksimum sapma miktarı (örneğin: 0.01 derece)
BEGIN
    -- Başlangıç ve bitiş noktalarını tanımlayın
    _start_loc := ST_SetSRID(ST_MakePoint(28.88706, 41.01858), 4326); -- Başlangıç noktası
    _end_loc := ST_SetSRID(ST_MakePoint(28.89706, 41.02858), 4326);   -- Bitiş noktası
    
    -- Başlangıç ve bitiş noktaları arasındaki mesafeyi ve yönü hesaplayın
    _distance := ST_Distance(_start_loc, _end_loc);
    _azimuth := ST_Azimuth(_start_loc, _end_loc);
    
    -- Her bir adım büyüklüğünü hesaplayın
    _step_size := _distance / _num_points;
    
    -- Her bir rota için döngüyü başlatın
    FOR _current_route IN 1.._num_routes LOOP
        -- Başlangıç noktası olarak ilk noktayı atayın
        _current_loc := _start_loc;
        INSERT INTO locations (point, time, route_id)
        VALUES (_current_loc, NOW(), _current_route);
        
        -- Rota başına nokta oluşturmayı başlatın
        WHILE ST_Distance(_current_loc, _end_loc) > _step_size LOOP
            -- Rastgele sapma miktarını hesaplayın
            DECLARE
                _deviation float := random() * _max_deviation * 2 - _max_deviation;
            BEGIN
                -- Yeni noktanın konumunu ve yönünü hesaplayın
                _current_loc := ST_Project(_current_loc, _step_size, _azimuth + _deviation);
                _azimuth := ST_Azimuth(_current_loc, _end_loc);
                
                -- Yeni noktayı tabloya ekleyin
                INSERT INTO locations (point, time, route_id)
                VALUES (_current_loc, NOW(), _current_route);
                
                -- Yeni noktanın oluşturulması ve ekrana yazdırılması (opsiyonel)
                RAISE NOTICE 'Route % - Point: %', _current_route, _current_loc;
            END;
        END LOOP;
        
        -- Son noktayı ekleyin
        INSERT INTO locations (point, time, route_id)
        VALUES (_end_loc, NOW(), _current_route);
    END LOOP;
END;
$$;

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
-- CHATGPT

select * from locations

select l.time, ST_AsText(point) as location, ST_Value(e.rast, ST_Transform(l.point, 4326)) as esenler
from locations l
inner join esenler e ON ST_Intersects(ST_ConvexHull(e.rast), ST_Transform(l.point, 4326));

with data_points as (
	select l.time, ST_Value(e.rast, ST_Transform(l.point, 4326)) as elevation, 
		RANK () OVER (ORDER BY time) as ordinal
	from locations l
	inner join esenler e ON ST_Intersects(ST_ConvexHull(e.rast), ST_Transform(l.point, 4326))
), elevation_deltas as (
	select dp1.ordinal, 
		dp2.elevation - dp1.elevation as delta, 
		case when dp1.elevation < dp2.elevation then 'ascent' else 'descent' end as direction
	from data_points dp1
	inner join data_points dp2 on dp2.ordinal = dp1.ordinal + 1
)
select (select sum(delta) from elevation_deltas where direction = 'ascent') as totalAscent,
(select sum(delta) from elevation_deltas where direction = 'descent') as totalDescent

with data_points as (
	select l.time, l.point,
		RANK () OVER (ORDER BY time) as ordinal
	from locations l
), distances AS (
	select ST_DistanceSphere(dp1.point, dp2.point) as distance, dp1.time
	from data_points dp1
	inner join data_points dp2 on dp2.ordinal = dp1.ordinal + 1
)
select sum(distance) / 1000 as total_distance_km, 
	extract(epoch from max(time) - min(time)) / 3600 as total_hours, 
	(sum(distance) / 1000) / (extract(epoch from max(time) - min(time)) / 3600) as avg_speed_kmh
from distances;

select ST_AsGeoJSON(line)
from route
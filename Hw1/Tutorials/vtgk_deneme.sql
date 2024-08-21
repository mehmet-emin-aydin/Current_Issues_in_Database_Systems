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
    _max_deviation float := 0.6; -- Maksimum sapma miktarı (örneğin: 0.01 derece)
    _time_counter int; -- Zaman sayacı
BEGIN
    -- Başlangıç ve bitiş noktalarını tanımlayın
    _start_loc := ST_SetSRID(ST_MakePoint(28.88706, 41.01858), 4326); -- Başlangıç noktası
    _end_loc := ST_SetSRID(ST_MakePoint(28.90532, 41.03668), 4326);   -- Bitiş noktası
    
	
    -- Başlangıç ve bitiş noktaları arasındaki mesafeyi ve yönü hesaplayın
    _distance := ST_Distance(_start_loc, _end_loc);
    _azimuth := ST_Azimuth(_start_loc, _end_loc);
    -- Her bir adım büyüklüğünü hesaplayın
    _step_size := _distance / _num_points;
    DELETE FROM locations;
    -- Her bir rota için döngüyü başlatın
    FOR _current_route IN 1.._num_routes LOOP
        -- Başlangıç noktası olarak ilk noktayı atayın
        _current_loc := _start_loc;
		
        INSERT INTO locations (point, time, route_id)
        VALUES (_start_loc, 0, _current_route);
        _time_counter := 0;
        -- Rota başına nokta oluşturmayı başlatın
        WHILE ST_Distance(_current_loc, _end_loc) > _step_size*2 LOOP
            -- Rastgele sapma miktarını hesaplayın
            DECLARE
                _deviation float;
            BEGIN
                -- Zaman sayacını artır
                _time_counter := _time_counter + 1;
                
                -- Yeni noktanın konumunu ve yönünü hesaplayın
				_deviation := (random()*1.8-0.9);
                _current_loc := ST_Project(_current_loc, _step_size, _azimuth + _deviation);
                _azimuth := ST_Azimuth(_current_loc, _end_loc);
                RAISE NOTICE 'azimuth %  ',_deviation;

                -- Yeni noktayı tabloya ekleyin
                INSERT INTO locations (point, time, route_id)
                VALUES (_current_loc, _time_counter, _current_route);
                
                -- Yeni noktanın oluşturulması ve ekrana yazdırılması (opsiyonel)
                RAISE NOTICE 'Route % - Point: %', _current_route, _current_loc;
            END;
			
        END LOOP;
        
        -- Son noktayı ekleyin
        _current_loc := ST_Project(_current_loc, _step_size, _azimuth);
        _azimuth := ST_Azimuth(_current_loc, _end_loc);  
		INSERT INTO locations (point, time, route_id)
        VALUES (_current_loc, _time_counter+1, _current_route);
        INSERT INTO locations (point, time, route_id)
        VALUES (_end_loc, _time_counter+2, _current_route);
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


select * from locations

WITH data_points AS (
	SELECT route_id,
	       l.time,
	       ST_Value(e.rast, ST_Transform(l.point, 4326)) AS elevation,
	       RANK() OVER (PARTITION BY route_id ORDER BY l.time) AS ordinal
	FROM locations l
	INNER JOIN deneme e ON ST_Intersects(ST_ConvexHull(e.rast), ST_Transform(l.point, 4326))
), elevation_deltas AS (
	SELECT dp1.route_id,
	       dp1.ordinal,
	       dp2.elevation - dp1.elevation AS delta,
	       CASE WHEN dp1.elevation < dp2.elevation THEN 'ascent' ELSE 'descent' END AS direction
	FROM data_points dp1
	INNER JOIN data_points dp2 ON dp2.route_id = dp1.route_id AND dp2.ordinal = dp1.ordinal + 1
)
SELECT ed.route_id,
       (SELECT SUM(delta) FROM elevation_deltas WHERE direction = 'ascent' AND route_id = ed.route_id) AS totalAscent,
       (SELECT SUM(delta) FROM elevation_deltas WHERE direction = 'descent' AND route_id = ed.route_id) AS totalDescent
FROM elevation_deltas ed 
group by ed.route_id;



WITH data_points AS (
    SELECT 
        l.time, 
        l.point,
        l.route_id,
        RANK() OVER (PARTITION BY route_id ORDER BY time) AS ordinal
    FROM 
        locations l
), 
distances AS (
    SELECT 
        dp1.route_id,
        ST_DistanceSphere(dp1.point, dp2.point) AS distance, 
        dp1.time
    FROM 
        data_points dp1
    INNER JOIN 
        data_points dp2 ON dp2.ordinal = dp1.ordinal + 1 AND dp1.route_id = dp2.route_id
)
SELECT 
    distances.route_id,
    CAST(SUM(distance)/1000.0 AS DECIMAL(10,3)) AS total_distance_km, 
    CAST((max(time) - min(time))/1200.0 AS DECIMAL(10,3)) AS total_hours, 
    CAST(sum(distance)/1000.0 / ((max(time) - min(time))/1200.0) AS DECIMAL(10,1)) as avg_speed_kmh
FROM 
    distances
GROUP BY 
    distances.route_id;

select ST_AsGeoJSON(line)
from route




CREATE OR REPLACE VIEW current_racers_view AS
	WITH selected_area AS (
		SELECT 
			ST_SetSRID(ST_MakePolygon(ST_GeomFromText('POLYGON((41.0212114 28.8871625, 41.021955 28.897947, 41.027030 28.898178, 41.030145 28.890427, 41.0212114 28.8871625))')), 4326) AS area_polygon
	),
	current_positions AS (
		SELECT 
			l.route_id,
			l.point AS current_position,
			r.line AS route_line
		FROM 
			locations l
		INNER JOIN 
			selected_area sa ON ST_Within(l.point, sa.area_polygon)
		INNER JOIN 
			route r ON l.route_id = r.id
		WHERE 
			l.time=32 -- Belirli bir zamanı filtrelemek için	
	)
	SELECT 
		cp.route_id,
		cp.current_position,
		cp.route_line,
		sa.area_polygon -- Seçilen alanı da ekrana çıktıya dahil ediyoruz
	FROM 
		current_positions cp
	CROSS JOIN 
		selected_area sa; -- Tüm kayıtlar için aynı seçilen alanı kullanıyoruz

CREATE TABLE selected_area_table AS
SELECT 
    ST_SetSRID(ST_MakePolygon(ST_GeomFromText('POLYGON((41.0212114 28.8871625, 41.021955 28.897947, 41.027030 28.898178, 41.030145 28.890427, 41.0212114 28.8871625))')), 4326) AS geom;

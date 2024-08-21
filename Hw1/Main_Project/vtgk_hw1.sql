create extension if not exists "uuid-ossp"

create table locations (
	id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
	point geometry(Point,4326),
	time int
);

ALTER TABLE locations
ADD COLUMN route_id INT;

create index locations_point_idx ON locations using GIST(point);

DO $$
DECLARE
    _start_loc geometry;
    _end_loc geometry;
    _num_routes int := 11; -- rota sayısı
    _num_points int := 100; -- Rota başına oluşturulacak nokta sayısı
    _current_route int;
    _current_point int;
    _current_loc geometry;
    _step_size float;
    _distance float;
    _azimuth float;
    _max_deviation float := 1.2; --Sapma katsayısı
    _time_counter int; -- Zaman sayacı
BEGIN
    -- Başlangıç ve bitiş noktalarını tanımladıgımız yer
    _start_loc := ST_SetSRID(ST_MakePoint(28.88706, 41.01858), 4326); -- Başlangıç noktası
    _end_loc := ST_SetSRID(ST_MakePoint(28.91785, 41.05945), 4326);   -- Bitiş noktası

    -- Başlangıç ve bitiş noktaları arasındaki mesafeyi ve yönü hesaplariz
    _distance := ST_Distance(_start_loc, _end_loc);
    _azimuth := ST_Azimuth(_start_loc, _end_loc);
    -- Her bir adım büyüklüğünü hesaplariz
    _step_size := _distance / _num_points;
    DELETE FROM locations;
    -- Her bir rota için döngü
    FOR _current_route IN 1.._num_routes LOOP
        -- Başlangıç noktası olarak ilk nokta olarak verdik her rota icin fix
        _current_loc := _start_loc;
		
        INSERT INTO locations (point, time, route_id)
        VALUES (_start_loc, 0, _current_route);
        _time_counter := 0;
        -- Her rota icin son mesafeye kadar point üretme dongusu
        WHILE ST_Distance(_current_loc, _end_loc) > _step_size*2 LOOP
            -- Rastgele sapma miktarını hesapladıgımız degisken
            DECLARE
                _deviation float;
            BEGIN
                -- Zaman sayacını tanimliyoruz
                _time_counter := _time_counter + 1;
                
                -- Yeni noktanın konumunu ve yönünü hesapliyoruz
				_deviation := (random()*_max_deviation*2-_max_deviation);
                _current_loc := ST_Project(_current_loc, _step_size, _azimuth + _deviation);
                _azimuth := ST_Azimuth(_current_loc, _end_loc);
                RAISE NOTICE 'azimuth %  ',_deviation;

                -- Yeni noktayı tabloya rotaya ekliyoruz
                INSERT INTO locations (point, time, route_id)
                VALUES (_current_loc, _time_counter, _current_route);
                
                -- Yeni noktanın oluşturulması ve ekrana yazdırılması için raise
                RAISE NOTICE 'Route % - Point: %', _current_route, _current_loc;
            END;
			
        END LOOP;
        
        -- Son noktayı ekleriz ki herkes bitise varsin en sonda
        _current_loc := ST_Project(_current_loc, _step_size, _azimuth);
        _azimuth := ST_Azimuth(_current_loc, _end_loc);  
		INSERT INTO locations (point, time, route_id)
        VALUES (_current_loc, _time_counter+1, _current_route);
        INSERT INTO locations (point, time, route_id)
        VALUES (_end_loc, _time_counter+2, _current_route);
    END LOOP;
END;
$$;

-- olusturduğumuz rota noktalarını çizgi ile birleştirip view oluşturuyoruz
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


-- yarismacilarin hangi sirayla bitirdiklerini olusturdugumuz view

CREATE OR REPLACE VIEW race_results_view AS
SELECT 
  ROW_NUMBER() OVER (ORDER BY MAX(time)::double precision) AS sira_no,
  route_id AS yarismaci_no,
  MAX(time)::double precision AS bitirme_suresi
FROM locations
GROUP BY route_id
ORDER BY bitirme_suresi ASC;

select *
from race_results_view;


-- YÜKSELME VE ALÇALMA katman sayisini burada hesapliyoruz
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
from elevation_changes_view;


-- HER YARIŞMACININ TOPLAMDA ALDIĞI YOLU VE KALORISINI HESAPLADIGIMIZ View
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
from race_distances_view;


--secilen polygonal alanda belirtilen zamanda bulunan yarısmacilarin point verileri burada 
CREATE OR REPLACE VIEW routes_in_polygon AS (
    WITH polygon_area AS (
        SELECT 
            ST_GeomFromText('POLYGON((28.8961 41.0290, 28.8960 41.0306, 28.8912 41.0304, 28.8901 41.0287, 28.8961 41.0290))', 4326) AS geom -- Örnek olarak bir alan belirtiyorum, siz gerçek verilerinize göre bu alanı değiştirebilirsiniz
    ),
    route_points AS (
        SELECT 
            route_id,
            point,
            time
        FROM 
            locations
        WHERE 
            ST_Within(locations.point, (SELECT geom FROM polygon_area))
			AND time=34
    )
    SELECT 
        route_id,
        point,
        time
    FROM 
        route_points
);

SElect count(time),time from routes_in_polygon group by time;
-- Opens "session B": a second, independent connection to the same database.
SET search_path TO lagoonpay, public;
\pset pager off
\o /dev/null
SELECT dblink_disconnect(c) FROM unnest(dblink_get_connections()) AS c WHERE c = 'B';
SELECT format('dbname=%I port=%s user=%I%s',
              current_database(), current_setting('port'), current_user,
              CASE WHEN split_part(current_setting('unix_socket_directories'), ',', 1) <> ''
                   THEN ' host=' || trim(split_part(current_setting('unix_socket_directories'), ',', 1))
                   ELSE '' END) AS connstr \gset
SELECT dblink_connect('B', :'connstr') AS session_b_connected;
SELECT dblink_exec('B', 'SET search_path TO lagoonpay, public') AS session_b_ready;
\o
\qecho 'Session B connected (second database connection opened with dblink).'

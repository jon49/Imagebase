-- Published pages are files now: <pages-dir>/<id>.html, served by the web
-- server, with the page's space in <pages-dir>/.spaces/<id>. maintenance.goose
-- writes every row out before this runs (and refuses without --pages-dir when
-- there are rows), so dropping the table loses nothing.
DROP TABLE pages;

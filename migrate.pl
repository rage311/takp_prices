#!/usr/bin/env perl

use Mojo::SQLite;

my $sql = Mojo::SQLite->new('./takp_prices.db');

# Use migrations to create a table
$sql->migrations->from_data('main')->migrate(0)->migrate;
#$sql->migrations->from_data('main')->migrate;


__DATA__

# CONSTRAINT uniq UNIQUE (item_id, trader_id, price_cp)

@@ migrations
-- 2 up
CREATE VIEW instances_unique AS
  SELECT
    timestamp,
    item_id,
    quantity,
    trader_id,
    price_cp,
    price_pp
  FROM instances
  GROUP BY price_pp, item_id, trader_id;

-- 1 up
CREATE TABLE IF NOT EXISTS "items" (
  id         INTEGER NOT NULL UNIQUE PRIMARY KEY,
  name 			 TEXT NOT NULL,
  stats_html TEXT,
  stats_json TEXT,
  icon_id 	 INTEGER
);

CREATE INDEX IF NOT EXISTS index_name ON items (name);

CREATE TABLE instances (
  timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  item_id   INTEGER NOT NULL,
  quantity  INTEGER NOT NULL,
  trader_id INTEGER NOT NULL,
  price_cp  INTEGER NOT NULL,
  price_pp  INTEGER NOT NULL,
  bytes     TEXT NOT NULL,
  FOREIGN KEY(item_id) REFERENCES items(id)
);

CREATE INDEX IF NOT EXISTS index_timestamp ON instances (timestamp);
CREATE INDEX IF NOT EXISTS index_item_id   ON instances (item_id);
CREATE INDEX IF NOT EXISTS index_trader_id ON instances (trader_id);
CREATE INDEX IF NOT EXISTS index_price_cp  ON instances (price_cp);
CREATE INDEX IF NOT EXISTS index_price_pp  ON instances (price_pp);

-- 1 down
DROP INDEX index_name;
DROP INDEX index_timestamp;
DROP INDEX index_item_id;
DROP INDEX index_trader_id;
DROP INDEX index_price_cp;
DROP INDEX index_price_pp;
DROP TABLE IF EXISTS items;
DROP TABLE IF EXISTS instances;


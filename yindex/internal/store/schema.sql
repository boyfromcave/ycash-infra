-- yindex: the transparent address index. One writer (the ingester), many readers.
CREATE TABLE IF NOT EXISTS blocks (
  height  BIGINT PRIMARY KEY,
  hash    TEXT NOT NULL,
  time    BIGINT NOT NULL
);
-- Every transparent output ever, with where it was spent (NULL = unspent).
CREATE TABLE IF NOT EXISTS outputs (
  address      TEXT   NOT NULL,
  txid         BYTEA  NOT NULL,
  vout         INT    NOT NULL,
  script       BYTEA  NOT NULL,
  value_zat    BIGINT NOT NULL,
  height       BIGINT NOT NULL,
  spent_txid   BYTEA,
  spent_height BIGINT,
  PRIMARY KEY (txid, vout)
);
CREATE INDEX IF NOT EXISTS outputs_address_unspent ON outputs (address, height) WHERE spent_height IS NULL;
CREATE INDEX IF NOT EXISTS outputs_address_height  ON outputs (address, height);
CREATE INDEX IF NOT EXISTS outputs_spent_height    ON outputs (spent_height) WHERE spent_height IS NOT NULL;
-- Every transaction touching a transparent address (as input or output), with its raw bytes,
-- so GetTaddressTxids streams RawTransaction without a node call. Ycash is small: ~0.9 M
-- outputs ever, so storing raw transactions is cheap.
CREATE TABLE IF NOT EXISTS address_txs (
  address TEXT   NOT NULL,
  txid    BYTEA  NOT NULL,
  height  BIGINT NOT NULL,
  PRIMARY KEY (address, txid)
);
CREATE INDEX IF NOT EXISTS address_txs_height ON address_txs (address, height);
CREATE TABLE IF NOT EXISTS txs (
  txid   BYTEA  PRIMARY KEY,
  height BIGINT NOT NULL,
  raw    BYTEA  NOT NULL
);
CREATE INDEX IF NOT EXISTS txs_height ON txs (height);

-- Runs once, on first start with an empty volume.
-- One database + one user per service; each user can only connect to its own database.

CREATE USER orders_svc   WITH PASSWORD 'orders';
CREATE USER tickets_svc  WITH PASSWORD 'tickets';
CREATE USER payments_svc WITH PASSWORD 'payments';
CREATE USER emails_svc   WITH PASSWORD 'emails';

CREATE DATABASE orders   OWNER orders_svc;
CREATE DATABASE tickets  OWNER tickets_svc;
CREATE DATABASE payments OWNER payments_svc;
CREATE DATABASE emails   OWNER emails_svc;

REVOKE CONNECT ON DATABASE orders   FROM PUBLIC;
REVOKE CONNECT ON DATABASE tickets  FROM PUBLIC;
REVOKE CONNECT ON DATABASE payments FROM PUBLIC;
REVOKE CONNECT ON DATABASE emails   FROM PUBLIC;

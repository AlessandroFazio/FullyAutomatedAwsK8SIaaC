-- -----------------------------------------------------------------------------
-- create ROLE and Database ----------------------------------------------------
-- -----------------------------------------------------------------------------
DO $$
BEGIN
CREATE USER keycloak ;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;

CREATE DATABASE keycloak WITH OWNER keycloak;
-- -----------------------------------------------------------------------------
-- Grant rds_iam role to the role created above --------------------------------
-- -----------------------------------------------------------------------------
GRANT rds_iam TO keycloak;
-- -----------------------------------------------------------------------------
-- connect to DB, create SCHEMA & set privileges -------------------------------
-- -----------------------------------------------------------------------------
\c keycloak
REVOKE ALL ON SCHEMA public FROM PUBLIC ;
CREATE SCHEMA keycloak AUTHORIZATION keycloak ;
ALTER ROLE keycloak SET search_path=keycloak ;
GRANT ALL ON ALL TABLES IN SCHEMA keycloak TO keycloak ;
REVOKE ALL ON DATABASE keycloak FROM PUBLIC ;




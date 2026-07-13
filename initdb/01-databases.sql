-- One database per Foundry Tier-3 app. Tenant isolation is enforced inside each database
-- with Row-Level Security keyed on the Nyquest owner id (see each app's db_pg.init()).
CREATE DATABASE visionlab OWNER foundry;
CREATE DATABASE voicelab  OWNER foundry;
CREATE DATABASE mcplab    OWNER foundry;
CREATE DATABASE swarmlab  OWNER foundry;

# DozerDB with OpenGDS baked in.
#
# Coolify deploys this repository as a Docker Compose resource, which copies
# only the transformed compose file and .env to the destination host — never
# the repository itself. It then pre-creates any missing bind-mount directory,
# empty. So a jar committed under ./neo4j/plugins and bind-mounted at /plugins
# never reaches production: the directory is there, the jar is not, and every
# gds.* call fails with "Unknown function 'gds.version'".
#
# Baking the jar into the image ships it with the deploy and pins it to the
# server version it was built against.
FROM graphstack/dozerdb:5.26.27.0

# This image resolves plugins from /plugins (server.directories.plugins).
# The directory does not exist in the base image; creating it here is what
# makes the entrypoint pick it up, and — because NEO4J_PLUGINS is set — the
# entrypoint chowns it to neo4j and writes apoc.jar alongside this jar at
# boot without touching anything else already in it.
COPY open-gds-2.13.11.jar /plugins/open-gds-2.13.11.jar

# Hot backup procedures (backup.database / backup.all) for Neo4j Community.
# Built from ~/Development/environment/neo4j-backup against this exact server
# version; rebuild it whenever the FROM tag changes. Needs backup.* in the
# unrestricted and allowlist procedure settings in docker-compose.yml.
COPY neo4j-hot-backup-5.26.27.0.jar /plugins/neo4j-hot-backup-5.26.27.0.jar

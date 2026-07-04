# services/db.ncl — database service skeleton for the dummy project.
#
# Nickel-native equivalent of services/db.yml.

{
  services = {
    db = {
      image = "postgres:16-alpine",
      environment = [
        "POSTGRES_USER=demo",
        "POSTGRES_PASSWORD=demo",
        "POSTGRES_DB=demo",
      ],
      volumes = ["db-data:/var/lib/postgresql/data"],
    },
  },
}
# services/web.ncl — web service skeleton for the dummy project.
#
# Nickel-native equivalent of services/web.yml.

{
  services = {
    web = {
      image = "nginx:1.27",
      ports = ["8080:80"],
      environment = [
        "DB_HOST=db",
        "DB_PORT=5432",
      ],
      volumes = ["web-data:/var/www/html"],
      depends_on = ["db"],
    },
  },
}
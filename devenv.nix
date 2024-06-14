{ pkgs, lib, config, inputs, ... }:
let
  # Select PHP version
  php = pkgs.php83;

  # Use for older versions of NodeJS, needs input `nixpkgs-nodejs`
  # pkgsNodejs = import
  #   inputs.nixpkgs-nodejs
  #   { inherit system; };
  localDomain = "laravel.local";

  buildDeps = {
    inherit php;
    inherit (php.packages) composer;
    inherit (pkgs) nodejs_20;
    # For older version of NodeJS: pkgsNodejs.nodejs-slim-8_x
  };

  devDeps = buildDeps // {
    inherit (pkgs) wp-cli;
    inherit (pkgs) gh;
    inherit (php.extensions) mysqli pdo pdo_mysql;
  };

  containerRuntimeDeps = {
    inherit php;
    inherit (php.extensions) mysqli pdo pdo_mysql;
    inherit (pkgs) nginx;
  };
in
{
  options.containerDeps = lib.mkOption {
    type = lib.types.package;
    description = "Dependencies for prod container.";
  };

  config = {
    name = "weland-wp";

    # outputs.devDeps = devDeps;
    # Override `.env`
    env = {
      # DB_HOST = "127.0.0.1";
      # NGINX_HOST = "localhost";
      # NGINX_PORT = 8081;
    };

    containerDeps = pkgs.buildEnv {
      name = "container-env";
      paths = builtins.attrValues containerRuntimeDeps;
    };

    # Include git
    packages = [ pkgs.git ] ++ builtins.attrValues devDeps;

    # scripts.build.exec = "./scripts/build.sh";
    scripts.rndport.exec = ''
      sed -i"" '/^NGINX_PORT/d' .env; echo NGINX_PORT=$((RANDOM % 29000 + 3000)) \
        >> .env
    '';
    # scripts.deploy.exec = "./scripts/deploy.sh";
    scripts.mysql-local.exec = with config.env; "mysql -u '${DB_USER}' --password='${DB_PASSWORD}' -h '${DB_HOST}' '${DB_NAME}' \"$@\"";

    certificates = [
      localDomain
    ];
    hosts."${localDomain}" = "127.0.0.1";

    languages.php = {
      enable = lib.mkDefault true;
      package = php;

      ini = ''
        memory_limit = 2G
        realpath_cache_ttl = 3600
        session.gc_probability = 0
        display_errors = On
        error_reporting = E_ALL
        error_log=/proc/self/fd/2
        access.log=/proc/self/fd/2
        zend.assertions = -1
        opcache.memory_consumption = 256M
        opcache.interned_strings_buffer = 20
        short_open_tag = 0
        zend.detect_unicode = 0
        realpath_cache_ttl = 3600
      '';

      fpm.pools.web = lib.mkDefault {
        settings = {
          "clear_env" = "no";
          "pm" = "dynamic";
          "pm.max_children" = 10;
          "pm.start_servers" = 2;
          "pm.min_spare_servers" = 1;
          "pm.max_spare_servers" = 10;
        };
      };
    };

    services.nginx = {
      enable = lib.mkDefault true;
      httpConfig = lib.mkDefault ''
        server {
          listen ${toString config.env.NGINX_PORT};
          listen ${toString config.env.NGINX_SSL_PORT} ssl;
          ssl_certificate     ${config.env.DEVENV_STATE}/mkcert/${localDomain}.pem;
          ssl_certificate_key ${config.env.DEVENV_STATE}/mkcert/${localDomain}-key.pem;
          # ssl_protocols       TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
          # ssl_ciphers         HIGH:!aNULL:!MD5;

          root ${config.env.DEVENV_ROOT}/public;
          index index.php index.html index.htm;
          server_name ${config.env.NGINX_HOST};

          error_page 497 https://$server_name:$server_port$request_uri;

          location / {
            try_files $uri $uri/ /index.php$is_args$args;
          }
          location ~ \.php$ {
            fastcgi_pass unix:${config.languages.php.fpm.pools.web.socket};
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            fastcgi_param QUERY_STRING  $query_string;
            fastcgi_param REQUEST_METHOD  $request_method;
            fastcgi_param CONTENT_TYPE  $content_type;
            fastcgi_param CONTENT_LENGTH  $content_length;
            fastcgi_param SCRIPT_FILENAME  $request_filename;
            fastcgi_param SCRIPT_NAME  $fastcgi_script_name;
            fastcgi_param REQUEST_URI  $request_uri;
            fastcgi_param DOCUMENT_URI  $document_uri;
            fastcgi_param DOCUMENT_ROOT  $document_root;
            fastcgi_param SERVER_PROTOCOL  $server_protocol;
            fastcgi_param GATEWAY_INTERFACE CGI/1.1;
            fastcgi_param SERVER_SOFTWARE  nginx/$nginx_version;
            fastcgi_param REMOTE_ADDR  $remote_addr;
            fastcgi_param REMOTE_PORT  $remote_port;
            fastcgi_param SERVER_ADDR  $server_addr;
            fastcgi_param SERVER_PORT  $server_port;
            fastcgi_param SERVER_NAME  $server_name;
            fastcgi_param HTTPS   $https if_not_empty;
            fastcgi_param REDIRECT_STATUS  200;
            fastcgi_param HTTP_PROXY  "";
            fastcgi_buffer_size 512k;
            fastcgi_buffers 16 512k;
            set $fastcgi_host $host;
            if ($http_x_forwarded_host != \'\') {
                set $fastcgi_host $http_x_forwarded_host;
            }
            fastcgi_param HTTP_HOST  $fastcgi_host;
          }
        }
      '';
    };

    services.mysql = {
      enable = true;
      # package = pkgs.mariadb_110;
      initialDatabases = lib.mkDefault [
        { name = config.env.DB_NAME; }
        # { name = mysql_test_database; }
      ];
      settings.mysql.port = config.env.DB_PORT;
      settings.mysqld.log_bin_trust_function_creators = 1;
      ensureUsers = lib.mkDefault [
        {
          name = config.env.DB_USER;
          password = config.env.DB_PASSWORD;
          ensurePermissions = {
            "${config.env.DB_NAME}.*" = "ALL PRIVILEGES";
            # "${mysql_test_database}.*" = "ALL PRIVILEGES";
          };
        }
      ];
    };

    # Exclude the source repo to make the container smaller.
    containers."processes".copyToRoot = ./public;

    # See full reference at https://devenv.sh/reference/options/
    dotenv.enable = true;
  };
}

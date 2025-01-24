#!/bin/bash
# Script de despliegue de aplicación Web Django
# Es requisito que la carpeta donde clonemos el proyecto se llame igual que la carpeta del proyecto, la cual contiene el archivo settings.py.
#Cualquier otra configuración diferente a la vista en el script, debe ser configurada manualmente.
#
# Autor : xXJuan_davidXx
#


set -e

##### Actualizar el sistema y descargar dependencias #####
echo "Actualizando el sistema..."
sudo apt update && sudo apt upgrade -y

echo "Instalando dependencias necesarias..."
sudo apt install -y python3 python3-pip python3-venv mysql-server nginx ufw

#### Creando un usuario para el proyecto web ####
echo "Creando usuario para el proyecto web..."
read -p "Ingresa el nombre del usuario para el proyecto: " WEB_USER #Se solicita el nombre del usuario
sudo adduser --disabled-login --gecos "" $WEB_USER

#### Instalación y configuración de MySQL ####
echo "Configurando MySQL..."
read -p "Ingresa el nombre de la base de datos: " DB_NAME #El nombre de la base de datos
read -p "Ingresa el usuario de la base de datos: " DB_USER #El usuario de la base de datos
read -sp "Ingresa la contraseña para el usuario de la base de datos: " DB_PASS #La contraseña de la base de datos
echo
sudo mysql -e "CREATE DATABASE $DB_NAME;"
sudo mysql -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
sudo mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

#### Clonar el proyecto Django desde GitHub ####
echo "Clonando proyecto Django desde GitHub..."
read -p "Ingresa la URL del repositorio Git: " GIT_REPO
read -p "Ingresa el nombre de la carpeta del proyecto. Esta debe ser igual al nombre del proyecto Django: " PROJECT_DIR
sudo -u $WEB_USER git clone $GIT_REPO /home/$WEB_USER/$PROJECT_DIR


#### Crear y activar entorno virtual ####
echo "Creando y activando entorno virtual..."
sudo -u $WEB_USER python3 -m venv /home/$WEB_USER/$PROJECT_DIR/venv
sudo -u $WEB_USER /home/$WEB_USER/$PROJECT_DIR/venv/bin/pip install --upgrade pip
sudo -u $WEB_USER /home/$WEB_USER/$PROJECT_DIR/venv/bin/pip install -r /home/$WEB_USER/$PROJECT_DIR/requirements.txt

#### Configurar Django para producción ####
echo "Configurando Django para producción..."
read -p "Ingresa el dominio o IP pública del servidor: " SERVER_DOMAIN
sudo sed -i "s/DEBUG = True/DEBUG = False/g" /home/$WEB_USER/$PROJECT_DIR/$PROJECT_DIR/settings.py
sudo sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = ['$SERVER_DOMAIN']/g" /home/$WEB_USER/$PROJECT_DIR/$PROJECT_DIR/settings.py

echo "Configurando archivos estáticos..."
sudo -u $WEB_USER /home/$WEB_USER/$PROJECT_DIR/venv/bin/python /home/$WEB_USER/$PROJECT_DIR/manage.py collectstatic --noinput

echo "Instalando y configurando Uvicorn..."
sudo -u $WEB_USER /home/$WEB_USER/$PROJECT_DIR/venv/bin/pip install uvicorn

#### Configuración de base de datos mysql con django ####
echo "Instalando mysqlclient para Django..."
sudo -u $WEB_USER /home/$WEB_USER/$PROJECT_DIR/venv/bin/pip install mysqlclient

echo "Configurando la base de datos en settings.py..."
SETTINGS_FILE="/home/$WEB_USER/$PROJECT_DIR/$PROJECT_DIR/settings.py"

sudo sed -i "/DATABASES = {/,+6c\ 
DATABASES = {\
    'default': {\
        'ENGINE': 'django.db.backends.mysql',\
        'NAME': '$DB_NAME',\
        'USER': '$DB_USER',\
        'PASSWORD': '$DB_PASS',\
        'HOST': 'localhost',\
        'PORT': '3306',\
    }\
}" $SETTINGS_FILE

echo "Ejecutando migraciones de la base de datos..."
sudo -u $WEB_USER /home/$WEB_USER/$PROJECT_DIR/venv/bin/python /home/$WEB_USER/$PROJECT_DIR/manage.py migrate


#### Configurando Supervisor ####
echo "Configurando Supervisor..."
sudo apt install -y supervisor
sudo systemctl enable supervisor
sudo systemctl start supervisor

##>>> Archivo de configuración de Supervisor
#Comprobar en caso de no funcionar
sudo tee /etc/supervisor/conf.d/$PROJECT_DIR.conf > /dev/null <<EOF
[program:uvicorn]
command=/home/$WEB_USER/$PROJECT_DIR/venv/bin/uvicorn $PROJECT_DIR.asgi:application --host 127.0.0.1 --port 8000 --log-level info 
directory=/home/$WEB_USER/$PROJECT_DIR
user=$WEB_USER
autostart=true
autorestart=true
stdout_logfile=/home/$WEB_USER/uvicorn.log
stderr_logfile=/home/$WEB_USER/uvicorn_error.log
process_name=%(program_name)s_%(process_num)02d
EOF

sudo systemctl restart supervisor


#### Configuración de Nginx ####
echo "Configurando Nginx..."
sudo tee /etc/nginx/sites-available/$PROJECT_DIR > /dev/null <<EOF
server {
    listen 80;
    server_name $SERVER_DOMAIN;

    location /static/ {
        root /home/$WEB_USER/$PROJECT_DIR;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/$PROJECT_DIR /etc/nginx/sites-enabled
sudo nginx -t
sudo systemctl restart nginx


#### EL CERTIFICADO LETSENCRYPT NO SE PNDRA EN ESTE SCRIPT, DEBE SER CONFIGURADO MANUALMENTE, ESTO EN CASO DE QUE SE EJECUTE EL SCRIPT EN UN PROYECTO LOCAL QUE NO NECESITA SSL####


#### Configuración de Firewall ####
echo "Configurando Firewall..."
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw enable


#### Instalación y configuración de Fail2Ban ####
echo "Instalando y Configurando Fail2Ban..."
sudo apt install -y fail2ban
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

echo "Modificando configuración para SSH en /etc/fail2ban/jail.local..."
sed -i '/^\[sshd\]/,/^$/c\[sshd]\nenabled = true\nport = ssh\nlogpath = /var/log/auth.log\nbackend = systemd' /etc/fail2ban/jail.local

echo "Reiniciando servicio Fail2Ban..."
systemctl restart fail2ban
systemctl enable fail2ban

echo "Verificando el estado de Fail2Ban..."
fail2ban-client status

echo "Configuración completada. Tu servidor Django está listo y accesible en http://$SERVER_DOMAIN"

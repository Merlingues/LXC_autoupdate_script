# LXC_autoupdate_script

[!Proxmox](https://img.shields.io/badge/Proxmox-VE-E57000?style=for-the-badge&logo=proxmox&logoColor=white)
[!Bash](https://img.shields.io/badge/Bash-Script-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)
[!Debian](https://img.shields.io/badge/Linux-Debian-A81D33?style=for-the-badge&logo=debian&logoColor=white)
[!LXC](https://img.shields.io/badge/LXC-Containers-333333?style=for-the-badge)
[!GPLv3](https://img.shields.io/badge/License-GPLv3-blue?style=for-the-badge)

Ce projet sert à mettre à jour automatiquement les conteneurs LXC sur un hôte PROXMOX

## Fonctionnalités 
- Backup
- MAJ packages
- MAJ LXC
- Test après MAJ _(en cours)_
- Alerte mail

## Installation 
Cloner le projet  :
```bash
sudo git clone https://github.com/Merlingues/LXC_autoupdate_script/
```

Déplacer le dossier et créer le dossier logs :
```bash 
sudo mkdir -p /opt/scripts/logs
sudo mv ./LXC_autoupdate_script/backupMaj.sh /opt/scripts
```

Rendre le script exécutable:
```bash
sudo chmod +x /opt/scripts/backupMaj.sh
```

Installer les packages nécessaires : 
```bash
sudo apt install msmtp msmtp-mta
```

Créer le fichier de configuration msmtp :
```bash
sudo nano /etc/msmtprc
```

Configurer msmtp (exemple avec mail orange) : 
```
# Paramètres par défaut
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

# Configuration du compte Orange
account        orange
host           smtp.orange.fr
port           465
tls_starttls   off
from           email.email@orange.fr
user           email.email@orange.fr
#Génerer le mot de passe applications dans orange.
password       passwordmail

# Définir ce compte comme défaut
account default : orange
```

Sécuriser le fichier msmtp :
```bash
sudo chmod 600 /etc/msmtprc
```

Ajouter la tâche planifié (ici 1 fois par semaine [Lundi à 12h00] ) :
```bash
sudo crontab -e
```
Ajouter dans le fichier cron cette ligne
```bash
0 12 * * 1 /opt/scripts/backupMaj.sh
```

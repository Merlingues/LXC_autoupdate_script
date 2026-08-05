# LXC_autoupdate_script

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



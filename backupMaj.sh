#!/bin/bash

#Initialisation des chemins d'accès.
backupDir=""
workDir=""
sendMail=""
serverName=""

#Initialisation des logs
logFile="$workDir/updateMaj_$(date +%F).log"
exec > >(tee -a "$logFile") 2>&1

#Variable Globale
nombreErreur=0
#Nombre de backup à garder sur le serveur
nombreBackup=2

#Récuperation des VMID des LXC allumés
vmids=$(pct list | awk 'NR>1 && $2=="running" {print $1}')

#Boucle de Sauvegarde puis de MAJ des LXC
for vmid in $vmids; do

	#Récuperation du nom du LXC
	name=$(pct config "$vmid" | grep '^hostname:' | awk '{print $2}')
	echo "[INFO] Traitement du LXC : $vmid - $name"

	#Sauvergarde
	echo "[INFO] Sauvegarde du conteneur : $vmid - $name"

	if ! vzdump "$vmid" --mode snapshot --compress zstd --dumpdir "$backupDir" ; then
		echo "[ERREUR] Echec de la sauvegarde du conteneur : $vmid - $name"
		((nombreErreur++))
		continue
	fi

	ls -t "$backupDir"/vzdump-lxc-$vmid-*.{tar,vma}.* 2>/dev/null | tail -n +$(($nombreBackup + 1)) | xargs -I {} rm -f "{}"

	#MAJ
	echo "Mise à jour du conteneur : $vmid - $name"

	#MAJ paquets
	if ! pct exec "$vmid" -- bash -c "apt update && apt upgrade -y && apt autoremove -y";then
		echo "[ERREUR] Echec de la mise à jour (APT) du conteneur :  $vmid - $name"
		((nombreErreur++))
		continue
	fi

	#MAJ conteneur
	if ! pct exec "$vmid" -- bash -c '"yes"|update'; then
		echo "[ERREUR] Echec de la mise à jour (LXC) du conteneur :  $vmid - $name"
		((nombreErreur++))
		continue
	fi

	#Test Générique POSTMAJ
	#1. Test ICMP
	if ! pct exec "$vmid" -- bash -c "ping -c 4 9.9.9.9"; then
		echo "[Erreur] Echec du Test ICMP :  $vmid - $name"
		((nombreErreur++))
	fi

	#2. Test DNS
	if [[ -z "$(pct exec "$vmid" -- bash -c "dig +short proton.me")" ]]; then
		echo "[Erreur] Echec du Test DNS : $vmid - $name"
		((nombreErreur++))
	fi

	#Test des ports en écoute
	apres=$(pct exec "$vmid" -- bash -c "ss -Htuln | awk '{print \$5}' | awk -F':' '{if (\$NF < 32768) print \$NF}' | sort -n | uniq")
	if [[ "$avant" != "$apres" ]]; then
		echo "[Erreur] Echec du Test des ports : $vmid - $name"
		((nombreErreur++))
	fi

	#Test globale du système
	if ! pct exec "$vmid" -- bash -c "systemctl is-system-running"; then
		echo "[Erreur] Echec du Test globale système : $vmid - $name"
		((nombreErreur++))
	fi

	#Identification des échecs
	if [[ -n "$(pct exec "$vmid" -- bash -c "systemctl list-units --state=failed --no-legend")" ]]; then
		echo "[Erreur] Echec(s) détecté(s) : $vmid - $name"
		((nombreErreur++))
	fi

	#Test espace disque
	espaceUtil=$(pct exec "$vmid" -- bash -c "df -h /" | awk 'NR>1 {print $5}' | tr -d '%')
	if [[ "$espaceUtil" -ge 90 ]] ; then
		echo "[Erreur] Espace disque critique (>90%) : $vmid - $name"
		((nombreErreur++))
	fi

	#Test permissions d'écriture
	if ! pct exec "$vmid" -- bash -c "touch /tmp/test_$(date +%s) && rm /tmp/test_*"; then
		echo "[Erreur] Echec du Test permission d'écriture"
		((nombreErreur++))
	fi
done

#Notification par mail
if [ "$nombreErreur" -gt 0 ]; then
	echo "[ALERTE] $nombreErreur erreur(s) détectée(s). Envoi d'un mail"
	mail -s "[ALERTE] : Erreur Maj Proxmox "$serverName"" "$sendMail" < "$logFile"
	exit 1
else
	echo "[SUCCES] Toutes les actions se sont terminées avec succès."
	exit 0
fi

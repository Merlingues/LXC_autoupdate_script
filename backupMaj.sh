#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#Initialisation des chemins d'accès.
backupDir=""
workDir=""
sendMail=""
sendDiscord="" #Url weebhook discord
serverName=""

#Initialisation des logs
logFile="$workDir/updateMaj_$(date +%F).log"
sendFile="/tmp/Error_$(date +%F).log"
exec > >(tee -a "$logFile") 2>&1

#Variable Globale
nombreErreur=0
nombreBackup=2

#Récuperation des VMID des LXC allumés
vmids=$(pct list | awk 'NR>1 && $2=="running" {print $1}')

#Boucle de Sauvegarde puis de MAJ des LXC
for vmid in $vmids; do

	#Récuperation du nom du LXC
	name=$(pct config "$vmid" | grep '^hostname:' | awk '{print $2}')
	avant=$(pct exec "$vmid" -- bash -c "ss -Htuln 2>&1 | awk '{print \$5}' | awk -F':' '{if (\$NF < 32768) print \$NF}' | sort -n | uniq")
	echo "[INFO] Traitement du LXC : $vmid - $name"


	#Sauvergarde
	echo "[INFO] Sauvegarde du conteneur : $vmid - $name"
	resultat=$(vzdump "$vmid" --mode snapshot --compress zstd --dumpdir "$backupDir" 2>&1)
	code=$?
	echo "$resultat"
	if [[ $code -ne 0 ]] ; then
		echo "[ERREUR] Echec de la sauvegarde du conteneur : $vmid - $name" | tee -a "$sendFile"
		echo "Détails techniques : $resultat" | tee -a "$sendFile"
		((nombreErreur++))
		continue
	fi

	ls -t "$backupDir"/vzdump-lxc-$vmid-*.{tar,vma}.* 2>/dev/null | tail -n +$(($nombreBackup + 1)) | xargs -I {} rm -f "{}"

	#MAJ
	echo "Mise à jour du conteneur : $vmid - $name"

	#MAJ paquets
	resultat=$(pct exec "$vmid" -- bash -c "apt-get update && apt-get upgrade -y && apt-get autoremove -y" 2>&1)
	code=$?
	echo "$resultat"
	if [[ $code -ne 0 ]] ; then
		echo "[ERREUR] Echec de la mise à jour (APT-GET) du conteneur : $vmid - $name" | tee -a "$sendFile"
		echo "Détails techniques : $resultat" | tee -a "$sendFile"
		((nombreErreur++))
		continue
	fi

	#MAJ conteneur
	resultat=$(pct exec "$vmid" -- bash -c '"yes"|update' 2>&1)
	code=$?
	echo "$resultat"
	if [[ $code -ne 0 ]] ; then
		echo "[ERREUR] Echec de la mise à jour (LXC) du conteneur :  $vmid - $name" | tee -a "$sendFile"
		echo "Détails techniques : $resultat" | tee -a "$sendFile"
		((nombreErreur++))
		continue
	fi

	#Test Générique POSTMAJ
	#1. Test ICMP
	resultat=$(pct exec "$vmid" -- bash -c "ping -c 4 9.9.9.9" 2>&1)
	code=$?
	echo "$resultat"
	if [[ $code -ne 0 ]] ; then
		echo "[Erreur] Echec du Test ICMP :  $vmid - $name" | tee -a "$sendFile"
		echo "Détails techniques : $resultat" | tee -a "$sendFile"
		((nombreErreur++))
	fi

	#2. Test DNS
	resultat=$(pct exec "$vmid" -- bash -c "dig +short proton.me" 2>&1)
	code=$?
	echo "$resultat"
	if [[ $code -ne 0 ]] || [[ -z "$resultat" ]]; then
		echo "[ERREUR] Echec du Test DNS : $vmid - $name" | tee -a "$sendFile"
		if [[ -z "$resultat" ]]; then
			echo "Détails techniques : Aucune adresse IP retournée (Erreur de résolution)" | tee -a "$sendFile"
		else
			echo "Détails techniques : $resultat" | tee -a "$sendFile"
		fi
		((nombreErreur++))
	fi

	#Test des ports en écoute
	apres=$(pct exec "$vmid" -- bash -c "ss -Htuln 2>&1 | awk '{print \$5}' | awk -F':' '{if (\$NF < 32768) print \$NF}' | sort -n | uniq")
	code=$?
	if [[ $code -ne 0 ]]; then
		echo "[ERREUR] Echec du Test des ports sur le conteneur : $vmid - $name" | tee -a "$sendFile"
		echo "Détails techniques : $apres" | tee -a "$sendFile"
		((nombreErreur++))
	elif [[ "$avant" != "$apres" ]]; then
		echo "[ERREUR] Modification  des ports d'écoute : $vmid - $name" | tee -a "$sendFile"
		{
			echo "Détails techniques : Des services ont planté ou démarré inopinément."
			echo "--- Ports AVANT la mise à jour ---"
			echo "$avant"
			echo "--- Ports APRES la mise à jour ---"
			echo "$apres"
		} | tee -a "$sendFile"
		((nombreErreur++))
	fi

	#Test globale du système
	resultat=$(pct exec "$vmid" -- bash -c "systemctl is-system-running" 2>&1)
	code=$?
	echo "$resultat"
	if [[ $code -ne 0 ]] ; then
		echo "[Erreur] Echec du Test globale système : $vmid - $name" | tee -a "$sendFile"
		echo "Détails techniques : $resultat" | tee -a "$sendFile"
		((nombreErreur++))
	fi

	#Identification des échecs
	resultat=$(pct exec "$vmid" -- bash -c "systemctl list-units --state=failed --no-legend" 2>&1)
	code=$?
	echo "$resultat"
	if [[ $code -ne 0 ]] || [[ -n "$resultat" ]]; then
		echo "[Erreur] Echec(s) détecté(s) : $vmid - $name" | tee -a "$sendFile"
		echo "Détails techniques : $resultat" | tee -a "$sendFile"
		((nombreErreur++))
	fi

	#Test espace disque
	df_brut=$(pct exec "$vmid" -- bash -c "df -h /" 2>&1)
	code=$?
	echo "$df_brut"
	if [[ $code -ne 0 ]]; then
		echo "[Erreur] Echec de la commande df sur le conteneur : $vmid - $name" | tee -a "$sendFile"
		echo "Détails techniques : $df_brut" | tee -a "$sendFile"
		((nombreErreur++))
	else
		espaceUtil=$(echo "$df_brut" | awk 'NR>1 {print $5}' | tr -d '%')
		if [[ "$espaceUtil" -ge 90 ]] ; then
			echo "[Erreur] Espace disque critique (>90%) : $vmid - $name" | tee -a "$sendFile"
			echo "Détails techniques : $espaceUtil% d'espace utilisé sur /" | tee -a "$sendFile"
			((nombreErreur++))
		fi
	fi

	#Test permissions d'écriture
	resultat=$(pct exec "$vmid" -- bash -c "touch /tmp/test_$(date +%s) && rm /tmp/test_*" 2>&1)
	code=$?
	echo "$resultat"
	if [[ $code -ne 0 ]] ; then
		echo "[Erreur] Echec du Test permission d'écriture" | tee -a "$sendFile"
		echo "Détails techniques : $resultat" | tee -a "$sendFile"
		((nombreErreur++))
	fi

	#Récuperation des tags pour les tests spécifiques
	tags=$(pct config "$vmid" |/bin/grep "^tags:")

	#Test Docker
	if [[ "$tags" =~ docker ]]; then
		resultat=$(pct exec "$vmid" -- bash -c "docker info >/dev/null 2>&1" 2>&1)
		code=$?
		echo "$resultat"
		if [[ $code -ne 0 ]] ; then
			echo "[Erreur] Echec du Test Docker (inactif ou injoignable)" | tee -a "$sendFile"
			echo "Détails techniques : $resultat" | tee -a "$sendFile"
			((nombreErreur++))
		fi

	#Test pterodactyl (panel)
	elif [[ "$tags" =~ pterodactyl-panel ]]; then
		resultat=$(pct exec "$vmid" -- bash -c "cd /var/www/pterodactyl && php artisan migrate:status >/dev/null 2>&1 && curl -sS -I http://localhost 2>/dev/null" 2>&1)
		if ! echo "$resultat" | grep -q 'HTTP/'; then
			echo "[Erreur] Echec du Test Pterodactyl Panel (Base de données ou Web injoignable) : $vmid - $name" | tee -a "$sendFile"
			echo "Détails techniques : $resultat" | tee -a "$sendFile"
			((nombreErreur++))
		fi

	#Test pterodactyl (wings)
	elif [[ "$tags" =~ pterodactyl-wings ]]; then
		resultat=$(pct exec "$vmid" -- bash -c "curl -sS -I http://localhost:8080/api/system" 2>&1)
		if ! echo "$resultat" | grep -q 'HTTP/'; then
			echo "[Erreur] Echec du test Pterodactyl Wings (API locale injoignable) : $vmid - $name" | tee -a "$sendFile"
			echo "Détails techniques : $resultat" | tee -a "$sendFile"
			((nombreErreur++))
		fi

	#Test patchmon
	elif [[ "$tags" =~ patchmon ]]; then
		resultat=$(pct exec "$vmid" -- bash -c "curl -sS -I http://localhost:3000" 2>&1)
		if ! echo "$resultat" | grep -q 'HTTP/'; then
			echo "[Erreur] Echec du test PatchMon (Interface web injoignable sur le port 3000) : $vmid - $name" | tee -a "$sendFile"
			echo "Détails techniques : $resultat" | tee -a "$sendFile"
			((nombreErreur++))
		fi

	#Test Bezsel
	elif [[ "$tags" =~ bezsel ]]; then
		resultat=$(pct exec "$vmid" -- bash -c "curl -sS -I http://localhost:8090" 2>&1)
		if ! echo "$resultat" | grep -q 'HTTP/'; then
			echo "[Erreur] Echec du test Beszel (Interface web injoignable sur le port 8090) : $vmid - $name"| tee -a "$sendFile"
			echo "Détails techniques : $resultat" | tee -a "$sendFile"
			((nombreErreur++))
		fi

	#Test pihole
	elif [[ "$tags" =~ pihole ]]; then
		resultat=$(pct exec "$vmid" -- bash -c "curl -sS http://localhost/api/docs" 2>&1)
		if ! echo "$resultat" | grep -q 'enabled'; then
			echo "[Erreur] Echec du test Pi-hole (Moteur DNS FTL inactif ou web injoignable) : $vmid - $name"| tee -a "$sendFile"
			echo "Détails techniques : $resultat" | tee -a "$sendFile"
			((nombreErreur++))
		fi

	#Test homarr
	elif [[ "$tags" =~ homarr ]]; then
		resultat=$(pct exec "$vmid" -- bash -c "curl -sS -I http://localhost:7575" 2>&1)
		if ! echo "$resultat" | grep -q 'HTTP/'; then
			echo "[Erreur] Echec du test Homarr (Interface web injoignable sur le port 7575) : $vmid - $name"| tee -a "$sendFile"
			echo "Détails techniques : $resultat" | tee -a "$sendFile"
			((nombreErreur++))
		fi

	#Test nginxproxymanager
	elif [[ "$tags" =~ nginxproxxymanager ]]; then
		resultat=$(pct exec "$vmid" -- bash -c "curl -sS -I http://localhost:81" 2>&1)
		if ! echo "$resultat" | grep -q 'HTTP/'; then
			echo "[Erreur] Echec du test Nginx Proxy Manager (Interface d'administration injoignable sur le port 81) : $vmid - $name"| tee -a "$sendFile"
			echo "Détails techniques : $resultat" | tee -a "$sendFile"
			((nombreErreur++))
		fi

	fi
done

#Notification par mail
if [ "$nombreErreur" -gt 0 ]; then
	if [[ "$sendMail" != "" ]]; then
		echo "[ALERTE] $nombreErreur erreur(s) détectée(s). Envoi d'un mail" | tee -a "$sendFile"
		mail -s "[ALERTE] : Erreur Maj Proxmox $serverName" "$sendMail" < "$sendFile"
		exit 1
	elif [[ "$sendDiscord" != "" ]]; then
		echo "[ALERTE] $nombreErreur erreur(s) détectée(s). Envoi d'un message discord" | tee -a "$sendFile"
		curl -s -F "payload_json={\"content\": \"🚨 **[ALERTE]** $nombreErreur erreur(s) détectée(s) sur le serveur **$serverName**.\"}" \
			-F "file=@$sendFile" \
			"$sendDiscord" > /dev/null
		exit 1
	fi
else
	echo "[SUCCES] Toutes les actions se sont terminées avec succès."
	exit 0
fi

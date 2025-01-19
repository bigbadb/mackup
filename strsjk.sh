#!/bin/zsh

config_path="/Users/bjarneo/vscode/mackup/config.yaml"
home_dir="/Users/bjarneo"

# Hent ekskluderinger fra config.yaml
excludes=($(yq '.exclude[]' "$config_path"))

calculate_directory_size() {
   local dir="$1"
   du -sk "$dir" | cut -f1
}

calculate_backup_size() {
   local total_size=$(calculate_directory_size "$home_dir")
   local excluded_size=0

   # Beregn ekskludert størrelse
   for pattern in "${excludes[@]}"; do
       exclude_path="$home_dir/$pattern"
       if [[ -e "$exclude_path" ]]; then
           pattern_size=$(calculate_directory_size "$exclude_path")
           excluded_size=$((excluded_size + pattern_size))
       fi
   done

   local total_gb=$(echo "scale=2; $total_size / 1024 / 1024" | bc)
   local excluded_gb=$(echo "scale=2; $excluded_size / 1024 / 1024" | bc)
   local est_backup_size=$(echo "scale=2; $total_gb - $excluded_gb" | bc)

   echo "Total størrelse: $total_gb GB"
   echo "Ekskludert størrelse: $excluded_gb GB"
   echo "Antatt størrelse på backup: $est_backup_size GB"
}

calculate_backup_size

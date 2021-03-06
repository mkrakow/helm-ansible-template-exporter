#!/usr/bin/env bash
set -o pipefail
set -e

#3 Copy Exported Ansible in to operator generated by Operator-SDK
# Copy To  roles/{KNOWN ROLE}/defaults from roles/{KNOWN ROLE}/default
# Copy to roles/{KNOWN ROLE}/templates from roles/{KNOWN ROLE}/templates
# Copy to roles/{KNOWN ROLE}/tasks from roles/{KNOWN ROLE}/tasks
copy_assets() {
  source="$1"
  dst="$2"
  role="$3"
  echo $dst
  #Add this for testing only Ansible.
  cat >>"${dst}/roles/deploy.yaml" <<EOL
#Added from template exporter
---
# This playbook deploys k8s resources.
- hosts: localhost
  roles:
    - $role
EOL

  #Values file
  for file in $(find "$source/defaults" -iname '*.yml' -type f -printf "%P\n"); do
    cp "$source/defaults/$file" "$dst/roles/$role/defaults/${file}"
    sudo chmod 660 "$dst/roles/$role/defaults/${file}"
    add_chart_variables_to_values "$dst/roles/$role/defaults/${file}"
  done

  #Templates
  for file in $(find "$source/templates" -iname '*.j2' -type f -printf "%P\n"); do
    cp "$source/templates/$file" "$dst/roles/$role/templates/${file}"
    sudo chmod 660 "$dst/roles/$role/templates/${file}"
    #Temporary Solution For Template and Includes
    replace_chart_values_in_files "$dst/roles/$role/templates/${file}"
    if [[ "$role" == "zetcd" ]]; then
      replace_in_templates_for_zetcd "$dst/roles/$role/templates/${file}"
    fi
  done

  #Tasks
  for file in $(find "$source/tasks" -iname '*.yml' -type f -printf "%P\n"); do
    cp "$source/tasks/$file" "$dst/roles/$role/tasks/${file}"
    sudo chmod 660 "$dst/roles/$role/tasks/${file}"
    #Temporary Solution For Template and Includes
    replace_chart_values_in_files "$dst/roles/$role/tasks/${file}"
  done
}
usage() {
  echo "usage: build-operator.sh  [OPTION]"
  echo "Mandatory argument."
  echo "-e | --export : Export helmcharts and create Ansible operator"
  echo "-b | --build  : Build Operator image and push it to quay.io"
  echo "-d | --deploy : Deploy this operator to existing cluster"
  echo "-r | --run    : If you wish to debug, option to run the operator outside the cluster"
  echo "-c | --delete : Clean the cluster by deleteing the operator"
  echo "-h | --help   : Usage text"
}

export_helm() {
  make -C "$base_dir" example 2>&1
  if [[ "${?}" -ne 0 ]]; then
    echo "Could not export helm template due to above error.(Possible solution , run make clean)"
    exit 1
  fi
  echo "export is completed and stored in  ${workspace_base_dir}/$role directory"
}

generate_operator() {
  (cd ${workspace_base_dir}/ && operator-sdk new ${operator} --api-version=${api_version} --kind=${kind} --type=ansible) || true
  if [[ "${?}" -ne 0 ]]; then
    echo "Could not generate operator due to above error."
    cd "$working_dir"
    exit 1
  fi
  cd "$working_dir"
  echo "Operator is genrated at $operator_dir"
}

validate() {
  if [ ! -d "$workspace_base_dir" ]; then
  # shellcheck disable=SC2082
  echo "Workspace ${$workspace_base_dir} is not a valid path, please set workspace to a valid path"
  fi


  if [ -d "$template_dir" ]; then
    echo "please delete $template_dir or run make clean"
    exit 1
  fi
  if [ -d "$operator_dir" ]; then
    echo "please delete $operator_dir or run make clean"
    exit 1
  fi
}
#Create Chart.Name, Release.Varsion in dfault varaible files
replace_chart_values_in_files() {
  local file="${1}"
  #for mac os adding '' and -e
  sed -i.bak "s/.Chart./chart./g" "$file"
  sed -i.bak "s/.Release./release./g" "$file"
  rm "${file}.bak" #for mac os
}

#Add Chart.Name, Release.Varsion to default varaible files
add_chart_variables_to_values() {
  local file=${1}
  cat >>"$file" <<EOL
#Added from template exporter
chart:
  name: $role
  version: 1.0.0
release:
  name: $role
  service:
EOL
}

# This is for zetcd only - fixing the manual process
replace_in_templates_for_zetcd() {
  local file=${1}
  declare -A ChangeLogMessage=(
    ["template \"zetcd.fullname\" \."]=" Template is not support now , so use Chart name"
    ["template \"zetcd.name\" \."]=" Template is not support now , so use Chart name"
    ["replace \"+\" \"_\""]="Replace filter needs parentheses."
    ["{{ index .Values \"etcd-operator\" \"cluster\" \"name\" }}"]="Indexing values ,right way is to replace it by \\
                                                                    etcd-operator.cluster.name, but .name field is not available in values?? \\
                                                                    used random value for testing. This can be tricky."
    ["toYaml nodeSelector | indent 8"]="filters have to be piped and args are passed between paratheses"
    ["{{ toYaml resources | indent 12 }}"]="This needed condition check or else it will print empty {} \\
                                            which invalidates yaml"
    ["toYaml nodeSelector | indent 8"]="filters have to be piped and args are passed between paratheses"
    ["apiVersion: extensions\/v1beta1"]="k8s 1.6 depricated Deployment in the extensions\/v1beta1, \\
                                          apps\/v1beta1,So replaced it with apps\/v1"
    ["replicas: {{ replicaCount }}"]="spec.selector is required field as per  apps\/v1 spec and was missing."

  )

  declare -A postProcessing=(
    ["template \"zetcd.fullname\" \."]="chart.name"
    ["template \"zetcd.name\" \."]="chart.name"
    ["replace \"+\" \"_\""]="replace (\"+\",\"_\")"
    ["{{ index .Values \"etcd-operator\" \"cluster\" \"name\" }}"]="localhost" #"etcd-operator.cluster.name"
    ["{{ toYaml resources | indent 12 }}"]="{% if resources is defined and resources|length %}\\
                                                      {{ resources | to_yaml | indent (12) }}\\
                                                      {% endif %}"
    ["toYaml nodeSelector | indent 8"]="nodeSelector | to_yaml | indent (8)"
    ["{% if nodeSelector is defined %}"]="{% if nodeSelector is defined and nodeSelector|length %}"
    ["apiVersion: extensions\/v1beta1"]="apiVersion: apps\/v1"
    ["replicas: {{ replicaCount }}"]="replicas: {{ replicaCount }} \\
  selector: \\
    matchLabels: \\
      app: {{ chart.name }}"

  )

  printf "%-70s %s-50s %s\n" "Original Line" "Processed Line" "Reason"
  printf "%-70s %-50s %s \n" "-------------" "-------------" "-------------"
  for original_line in "${!postProcessing[@]}"; do
    #echo "Replacing $original_line ---- ${postProcessing[$original_line]}"
    printf "%-70s %-50s %s \n" "$original_line" "${postProcessing[$original_line]}" "${ChangeLogMessage[$original_line]}"
    printf "%s\n" " "
    sed -i.bak "s/${original_line}/${postProcessing[$original_line]}/g" "$file"
  done
  rm "${file}.bak" #for mac os
  printf "%-70s %-50s %s \n" "-------------" "-------------" "-------------"
}

#Build operator image
build_operator_image() {
  echo "-------------------------- --------------- "
  echo "           Build and publish operator        "
  echo "-------------------------- --------------- "
  cd "${workspace_base_dir}/${operator}"
  sed -i.bak "s/\"{{ REPLACE_IMAGE }}\"/REPLACE_IMAGE/g" ./deploy/operator.yaml
  sed -i.bak "s/\"{{ pull_policy|default('Always') }}\"/Always/g" ./deploy/operator.yaml
  sed -i.bak "s|REPLACE_IMAGE|quay.io/${quay_namespace}/${operator}:latest|g" ./deploy/operator.yaml

  operator-sdk build quay.io/$quay_namespace/$operator:latest

  docker push quay.io/$quay_namespace/$operator:latest
  #for mac os
  rm ./deploy/operator.yaml.bak
  cd "$base_dir"

}
#Deploy manifests for teh operator
deploy_manifests() {
  cd "./workspace/${operator}"
  for file in $(find "${workspace_base_dir}/${operator}/deploy/crds/" -iname '*crd.yaml' -type f -printf "%P\n"); do
    kubectl create -f "${workspace_base_dir}/${operator}/deploy/crds/${file}" || true
  done
  kubectl create -f "${workspace_base_dir}/${operator}/deploy/service_account.yaml" || true
  kubectl create -f "${workspace_base_dir}/${operator}/deploy/role.yaml" || true
  kubectl create -f "${workspace_base_dir}/${operator}/deploy/role_binding.yaml" || true
  for file in $(find "${workspace_base_dir}/${operator}/deploy/crds/" -iname '*cr.yaml' -type f -printf "%P\n"); do
    kubectl apply -f "${workspace_base_dir}/${operator}/deploy/crds/${file}" || true
  done
  cd "$base_dir"
}
# Deploy the operators to the cluster
deploy_operator() {
  echo "-------------------------- --------------- "
  echo "          Deploy to a cluster     "
  echo "-------------------------- --------------- "
  deploy_manifests
  cd "./workspace/${operator}"
  kubectl create -f "${workspace_base_dir}/${operator}/deploy/operator.yaml" || true
  cd "$base_dir"
}

# Delete operatros from the cluster
delete_operator() {
  echo "cd ./workspace/${operator}"
  kubectl delete -f "${workspace_base_dir}/${operator}/deploy/service_account.yaml" || true
  kubectl delete -f "${workspace_base_dir}/${operator}/deploy/role.yaml" || true
  kubectl delete -f "${workspace_base_dir}/${operator}/deploy/role_binding.yaml" || true
  kubectl delete -f "${workspace_base_dir}/${operator}/deploy/operator.yaml" || true

  for file in $(find "${workspace_base_dir}/${operator}/deploy/crds/" -iname '*.yaml' -type f -printf "%P\n"); do
    kubectl delete -f "${workspace_base_dir}/${operator}/deploy/crds/${file}" || true
  done
  cd "$base_dir"
}
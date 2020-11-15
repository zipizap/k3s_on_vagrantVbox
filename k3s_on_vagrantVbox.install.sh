#!/usr/bin/env bash
# Paulo Aleixo Campos
__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__dbg_on_off=on  # on off
function shw_info { echo -e '\033[1;34m'"$1"'\033[0m'; }
function error { echo "ERROR in ${1}"; exit 99; }
trap 'error $LINENO' ERR
function dbg { [[ "$__dbg_on_off" == "on" ]] || return; echo -e '\033[1;34m'"dbg $(date +%Y%m%d%H%M%S) ${BASH_LINENO[0]}\t: $@"'\033[0m';  }
#exec > >(tee -i /tmp/$(date +%Y%m%d%H%M%S.%N)__$(basename $0).log ) 2>&1
set -o errexit
  # NOTE: the "trap ... ERR" alreay stops execution at any error, even when above line is commente-out
set -o pipefail
set -o nounset
set -o xtrace

delete_if_k3smaster_already_exists() {
  if vagrant status &>/dev/null 
  then
    vagrant destroy --force 
  fi

}

exec_in_k3smaster() {
  local cmd="${1?missing arg}"; shift 
  #vagrant ssh --command /bin/bash -c "${cmd}"
  #vagrant ssh --command "${cmd}"
  cat <<EOT | vagrant ssh 
sudo /bin/bash -c "${cmd}"
EOT

}

scp_with_k3smaster() {
  local OPTIONS=`vagrant ssh-config | grep -v "^Host " | awk -v ORS=' ' '{print "-o " $1 "=" $2}'`
  scp ${OPTIONS} "$@" || echo "Transfer failed. Did you use 'default:' as the target?"
}


systemctl_k3s_status_or_logs() {
  #exec_in_k3smaster    'systemctl status k3s; journalctl -xeu k3s'
  #exec_in_k3smaster    'systemctl stop k3s; clear; k3s'
  exec_in_k3smaster    'systemctl --no-pager status k3s'
}

extract_and_load_kubeconfig() {
  rm kubeconfig.k3s.yaml || true
  #lxc file pull k3smaster/etc/rancher/k3s/k3s.yaml kubeconfig.k3s.yaml
  #scp_with_k3smaster root@default:/etc/rancher/k3s/k3s.yaml kubeconfig.k3s.yaml
  exec_in_k3smaster 'touch ~/.hushlogin'
  exec_in_k3smaster 'cat /etc/rancher/k3s/k3s.yaml' > kubeconfig.k3s.yaml
  sed -i 's:127.0.0.1:k3smaster:;s:default:k3s:g' kubeconfig.k3s.yaml
  export KUBECONFIG=$PWD/kubeconfig.k3s.yaml
  kubectl config use-context k3s
  kubectl get ingress,service,deploy,pods -A
}

report_memory_footprint() {
  echo "Reporting memory footprint"
  set +x
  for ((i=0; i<$(($1 / 5)); i++)); do
    local used_mem=$(exec_in_k3smaster "free --human --wide | head -2 | tail -1 | awk '{ print \$3 }'")
    shw_info "[$i/$(($1 / 5))] $used_mem"
    sleep 5
  done
  set -x
}

k__launch_busybox_deployment() {
  kubectl apply -f "${__dir}"/manifests/one-files/busybox.deployment.yaml
  sleep 2
  kubectl get all
  ## old friki code, from tests with NodePort
  ## Code looks so friki, that it deserves to remain as comment :)
  #IP_LxcK3smaster=$(lxc list k3smaster --format json | jq -r '.[0].state.network.eth0.addresses[0].address')
  # #nc $IP_LxcK3smaster 30001
  # # bonus shell-power
  # cat < /dev/tcp/$IP_LxcK3smaster/30001

  # Test the ingress service connection
  curl -kv http://k3smaster

}

k__patch_metrics_server() {
  # As of nov.2020, if "k top nodes" does not work properly, then probably the metrics-server is misconfigured and needs fixing
  # See https://github.com/kubernetes-sigs/kind/issues/398
  # UPDATE 2020.11.13 - this might be due to a bug in k3s_over_lxc, and might not be necessary at all in other scenarios (like in vbox-vm)
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.3.6/components.yaml
  kubectl patch deployment metrics-server -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"metrics-server","args":["--cert-dir=/tmp", "--secure-port=4443", "--kubelet-insecure-tls","--kubelet-preferred-address-types=InternalIP"]}]}}}}'
  sleep 5
  # kubectl top nodes should now start working after some minutes
}

vagrant_create_k3smaster() {
  vagrant up 
}

install_k3s_in_k3smaster() {
  exec_in_k3smaster  'apt-get install -y ca-certificates curl'
  #exec_in_k3smaster "echo 'L /dev/kmsg - - - - /dev/console' > /etc/tmpfiles.d/kmsg.conf"
  #exec_in_k3smaster reboot
  #sleep 5


  if [[ "${INSTALL_ISTIO}" == "true" ]]; then
    exec_in_k3smaster "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--no-deploy traefik'  sh -"  
  else
    exec_in_k3smaster 'curl -sfL https://get.k3s.io | sh -'
  fi
  # k3s version v1.18.9+k3s1 consumes 500-800MB ram when idle, before any workload... expected much lighter than that...
  # k3s version from jan2020: 1,26GB idle
  #exec_in_k3smaster  'curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.17.0+k3s.1  sh -'
  sleep 60

  systemctl_k3s_status_or_logs
}  

helm_setup_repo_stable() {
  # Helm: add repo stable
  # Note: all charts in https://github.com/helm/charts/tree/master/stable
  if helm repo list | grep stable &>/dev/null
  then
    helm repo remove stable
  fi
  helm repo add stable https://charts.helm.sh/stable &&\
  helm repo update
}

main__installOrReinstall_VboxVmK3smaster_and_inside_k3s() {

  delete_if_k3smaster_already_exists
  vagrant_create_k3smaster
  install_k3s_in_k3smaster

  extract_and_load_kubeconfig
    # ATP: kubectl/helm can be used against k3s cluster
  report_memory_footprint 20
  #k__patch_metrics_server
  helm_setup_repo_stable

}

helm_install_my-docker-registry_using_PVClocalPath() {
  # Optional: my-docker-registry 
  #  - via traefik-ingress, 
  #  - with persistent-storage on k3s "local-path"
  #helm \
  #  upgrade --install --atomic \
  #  my-docker-registry \
  #  stable/docker-registry \
  #  --values "${__dir}"/charts/docker-registry.values.yaml
  helm repo add twuni https://helm.twun.io
  helm \
    upgrade --install --atomic \
    my-docker-registry \
    twuni/docker-registry --version 1.9.6 \
    --values "${__dir}"/charts/docker-registry.values.yaml
}

main__install_istio() {
  ## https://istio.io/latest/docs/setup/getting-started/
  # Download
  if [[ ! -d "${__dir}/istio-1.7.4" ]]
  then
    curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.7.4 TARGET_ARCH=x86_64 sh -
  fi

  ISTIO_DIR=$(find $PWD -maxdepth 2 -type d -iname 'istio*')
  if [[ "${ISTIO_DIR}" ]];
  then
    # ISTIO_DIR found
    export PATH=$PATH:"${ISTIO_DIR}"/bin
  else
    echo "ISTIO_DIR not found... something went very wrong... aborting"
    exit 1
  fi
  cd "${ISTIO_DIR}"
  istioctl install --set profile=demo
  kubectl label namespace default istio-injection=enabled

  cd "${__dir}"
    # ATP: istioctl can be used (is in PATH)
}

parse_arguments() {
  INSTALL_MY_DOCKER_REGISTRY=false
  INSTALL_ISTIO=false
  # https://superuser.com/questions/186272/check-if-any-of-the-parameters-to-a-bash-script-match-a-string
  # idiomatic parameter and option handling in sh
  if [[ $# -eq 0 ]]; then
    cat <<EOT
Usage: $0 install-vagrantVbox [install-my-docker-registry] [install-istio]
EOT
    exit 1
  fi

  while test $# -gt 0
  do
      case "$1" in
          install-vagrantVbox) :
              ;;
          install-my-docker-registry) INSTALL_MY_DOCKER_REGISTRY=true
              ;;
          install-istio) INSTALL_ISTIO=true
              ;;
          *) echo "Unknown argument: '$1' - aborting"
						 exit 1
              ;;
      esac
      shift
  done
}


main() {
  parse_arguments "$@"

  # Install or reinstall VboxVm k3smaster, and inside k3s
  main__installOrReinstall_VboxVmK3smaster_and_inside_k3s 
    # At this point: 
    #  - We have the k3s cluster setup and up-and-running :)
    #  - kubectl/helm can be used against k3s cluster


  # Optional: my-docker-registry 
  #  - via traefik-ingress, 
  #  - with persistent-storage on k3s "local-path"
  if [[ "${INSTALL_MY_DOCKER_REGISTRY}" == "true" ]]; then
    helm_install_my-docker-registry_using_PVClocalPath
  fi

  # Optional: Launch a test deployment
  # k__launch_busybox_deployment

  # Install istio
  if [[ "${INSTALL_ISTIO}" == "true" ]]; then
    main__install_istio
      # ATP: istioctl can be used (is in PATH)
  fi


  cat <<'EOT'
Manually do:

  # add k3smaster into /etc/hosts
  sudo vi /etc/hosts
  ...
  k3smaster 1.2.3.4   (ip-of-k3smaster)

  # go happy hacking with the k3s cluster :)
  source "${__dir}"/k3s.source
  kubectl get namespaces
  k get all,ingress,persistentvolumeclaims

EOT

}

main "$@"

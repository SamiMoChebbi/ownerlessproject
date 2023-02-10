#!/bin/bash

set -e

package=$(echo ${0} | sed 's/.sh$//g')
while test $# -gt 0; do
  case "$1" in
    -h|--help)
      echo "$package - Transfer or delete an ownerless project space"
      echo " "
      echo "$package [options]"
      echo " "
      echo "options:"
      echo "-h, --help                Show brief help."
      echo "-d, --delete              Delete this project."
      echo "-n, --new-svc-acc         Specify new service account."
      echo "-p, --project             Specify project space."
      exit 0
      ;;
    -d|--delete)
      shift 1
      export DELETE="yes"
      ;;
    -n|--new-svc-acc)
      shift 1
      NEW=$1
      shift 1
      ;;
    -p|--project)
      shift 1
      PRJ=$1
      shift 1
      ;;
    *)
      break
      ;;
  esac
done

OLD=$(ssh root@cbox-mon-03 cernboxcop project getowner $PRJ)

if [ -z $DELETE ]; then
  echo "Starting the transfer of project: $PRJ from $OLD to $NEW ..."
else
  echo "Deleting project $PRJ ..."
fi

letter=${PRJ:0:1}

# Check ownership of the project in CBOX DB and make sure old doesn't exist and that new exists
ssh root@cbox-mon-03 cernboxcop project getowner $PRJ
# or 
ssh root@cbox-mon-03 cernboxcop project list | grep $PRJ
# and
# Get new and old (this will be a number if the old svc acc is gone) user ids.
OLD_SVC_ID=$(eos -r 0 0 root://eosproject-$letter.cern.ch ls -lha /eos/project/$letter/$PRJ | grep " \.$" | awk '{print $3}')
# id $NEW
NEW_SVC_ID=`id $NEW`

# Check shares owned by old svc account
ssh root@cbox-mon-03 cernboxcop sharing list | grep $OLD

## In EOS
# Change ACLs from old_svc_acc to new_svc_acc


if [ -z $DELETE ]; then
echo "Add new svc acc to cernbox-project-$PRJ-admins e-group"
FULLNAME=$(phonebook ${NEW} -t displayname)
EMAIL=$(phonebook ${NEW} -t email)
CCID=$(phonebook ${NEW} -t ccid)
python /opt/cbox-ops/upgrade-ownerless/ownerless-egroup.py ${PRJ} ${NEW} "${FULLNAME//;}" "${EMAIL//;}" "${CCID//;}"
fi

# Change ownership in eos to $NEW
# If there is an existing svc account in the -admins egroup and ownership is to this new acc just:
if [ -z $DELETE ]; then
# If no delete flag, means TRANSFER
  eos -r 0 0 root://eosproject-$letter.cern.ch chown -r <new_uid>:<new_gid> /eos/project/$letter/$PRJ
else
 If delete flag it means DELETE (Quarantine)
  eos -r 0 0 root://eosproject-$letter.cern.ch /eos/project/$letter/$PRJ /eos/project/.quarantine/$letter
fi

if [ -z $DELETE ]; then
# Create new_svc_acc quota in node and remove old_svc_acc quota
  # $2 current volume; $6 current inodes; $7 $8 old svc acc set volume; $11 $12 old svc acc set inodes
  VALUES=$(eos -r 0 0 root://eosproject-$letter.cern.ch quota ls -p /eos/project -u $OLD -m | tr '=' ' ' | awk '{print $14" "$18}')
  used_V=$(echo $VALUES | awk -F"::" 'print $1' |  awk -F"_" '{print $1}')
  used_I=$(echo $VALUES | awk -F"::" 'print $1' | awk -F"_" '{print $2}')
  quota_V=$(echo $VALUES | awk '{print $1}')
  quota_I=$(echo $VALUES | awk '{print $2}')

  eos -r 0 0 root://eosproject-$letter.cern.ch quota set -v $quota_V -i $quota_I -p /eos/project/  -u $NEW
  eos -r 0 0 root://eosproject-$letter.cern.ch quota rm -p /eos/project -u $OLD
else
  eos -r 0 0 root://eosproject-$letter.cern.ch quota rm -p /eos/project -u $OLD
fi

# If no shares update ownership of the project
if [ -z $DELETE ]; then
  ssh root@cbox-mon-03 cernboxcop project update-svc-account $PRJ $NEW
else
  ssh root@cbox-mon-03 cernboxcop project delete $PRJ
fi

# Rename recycle bin path
if [ -z $DELETE ]; then
  eos -r 0 0 root://eosproject-$letter.cern.ch mv /eos/project-$letter/proc/recycle/uid:<old_uid>/ /eos/project-$letter/proc/recycle/uid:<new_uid>
  if [ $? -eq 0 ]; then
  echo chown -R  <new_uid>:<new_gid> /eos/project-$letter/proc/recycle/uid:<new_id>
  else
    echo "Failed"
  fi
else
  echo "NOT removing the recycle bin"
fi

if [ -z $DELETE ]; then
  # Reset RESTIC backup for old and new svc acc. (This is old backup need to be seen if new backup has been fully)
  JOB_ID=$(ssh root@cback-backup-01 cback backup status $OLD | awk '{print $2}'| grep -P [0-9]+)
  ssh root@cback-backup-01 "cback backup modify $JOB_ID --user_name=$NEW"
  ssh root@cbox-backup-01 "cback backup reset $JOB_ID"
fi

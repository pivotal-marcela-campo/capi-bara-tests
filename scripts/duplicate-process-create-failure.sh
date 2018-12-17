#!/bin/sh

set -exu

CF_API_ENDPOINT=$(cf api | grep -i "api endpoint" | awk '{print $3}')
DOMAIN="${CF_API_ENDPOINT:12}"
appName=app
spaceName=space
SPACE_GUID=$(cf space $spaceName --guid)
envVars='{"foo": "bar"}'

#DROPLET_GUID=d169c110-b392-4921-a650-a775171ac3de
#APP_GUID=$(cf app $appName --guid)
if true ; then

args=$(printf '{"name":"%s", "relationships": {"space": {"data": {"guid": "%s"}}}, "environment_variables": {"foo":"bar"} }' $appName $SPACE_GUID)
#echo $args
#exit 0

cf delete -f $appName || true
APP_GUID=$(cf curl /v3/apps -X POST -d "$args" | tee /dev/tty | jq -r .guid)
echo $APP_GUID

#APP_GUID=f5023a00-2624-473f-8bbb-449574e26b1a

PACKAGE_GUID=$(cf curl /v3/packages -X POST -d "$(printf '{"relationships": {"app": {"data": {"guid": "%s"}}}, "type": "bits"}' $APP_GUID)" | tee /dev/tty | jq -r .guid)

echo $PACKAGE_GUID

if [ ! -f my-app.zip ] ; then
  D1=$PWD
  cd $HOME/go/src/github.com/cloudfoundry/cf-acceptance-tests/assets/dora
  zip -r $D1/my-app.zip .
  cd $D1
fi

curl -k "$CF_API_ENDPOINT/v3/packages/$PACKAGE_GUID/upload" -F bits=@"my-app.zip" -H "Authorization: $(cf oauth-token | grep bearer)"

while : ; do
  state=$(cf curl /v3/packages/$PACKAGE_GUID | jq -r '.state')
  case $state in
  "FAILED") echo "Failed to stage the package" ; exit 1 ;;
  "READY") break ;;
  "PROCESSING_UPLOAD") echo PROCESSING_UPLOAD... ;;
  *) echo "Unexpected state: $state" ; exit 1 ;;
  esac
  sleep 0.5
done

stageBody="$(printf '{"lifecycle": {"type": "buildpack", "data": {"buildpacks": ["ruby_buildpack"] } }, "package": { "guid" : "%s"}}' $PACKAGE_GUID)"
BUILD_GUID=$(cf curl /v3/builds -X POST -d "$stageBody" | tee /dev/tty | jq -r .guid)
echo $BUILD_GUID

while : ; do
  state=$(cf curl /v3/builds/$BUILD_GUID | jq -r '.state')
  case $state in
  "FAILED") echo "Failed to build the build" ; exit 1 ;;
  "STAGED") break ;;
  "STAGING") echo ${state}... ;;
  *) echo "Unexpected state: $state" ; exit 1 ;;
  esac

  sleep 0.5
done
 

DROPLET_GUID=$(cf curl /v3/builds/$BUILD_GUID | jq -r '.droplet.guid')
cf curl /v3/apps/$APP_GUID/relationships/current_droplet -X PATCH -d "$(printf '{"data": {"guid": "%s"}}' "$DROPLET_GUID")"

fi # false

for processType in $(cf curl /v3/apps/$APP_GUID/processes | jq -r '.resources[].type') ; do
  cf curl /v3/apps/$APP_GUID/processes/$processType/actions/scale -X POST -d '{"memory_in_mb": "256"}'
done

cf create-route space $DOMAIN -n $appName
ROUTE_GUID=$(cf curl /v2/routes?q=host:$appName | jq -r '.resources[].metadata.guid' | head -1)
cf curl /v2/routes/$ROUTE_GUID/apps/$APP_GUID -X PUT

cf curl /v3/apps/$APP_GUID/processes/web/actions/scale -X POST -d '{"instances": "4"}'
cf curl /v3/apps/$APP_GUID/actions/start -X POST


cf app $appName

#!/bin/bash

projectid="blis-jslibs"

#Deploy JS libraries
gsutil -m cp libs/*  gs://blis-bigquery-jslibs/

#regions where to deploy. default_us is there to denote the default wich is US and not qualified
regions=( us default_us us-east4 )


#create datsets if it does not exist Datasets in all regions
ls sql | sort -z|while read libname; do
  #we iterate over the regions
  for reg in "${regions[@]}"
  do
    #we create the daset with no region for backwards compatibility
    if [[ "$reg" == "default_us" ]];
    then
      region="us"
      datasetname="$libname"
    else
      region="$reg"
      datasetname="${reg}_${libname}"
    fi

    datasetname=$(echo "$datasetname" | sed -r 's/-/_/g')

    #create the dataset
    bq --project_id="$projectid" --location="$region" mk -d \
    --description "Dataset in ${region} for functions of library: ${libname}" \
    "$datasetname"

    #To add allAuthenticatedUsers to the dataset we grab the just created permission
    bq --project_id="$projectid" show --format=prettyjson \
    "$projectid":"$datasetname" > permissions.json

    #add the permision to temp file
    sed  '/"access": \[/a {"role": "READER","specialGroup": "allAuthenticatedUsers"},' permissions.json > updated_permission.json

    #we update with the new permissions file
    bq --project_id="$projectid" update --source updated_permission.json "$project":"$datasetname"

    #cleanup
    rm updated_permission.json
    rm permissions.json
  done
done


#We go over all the SQLs and replace for example jslibs.s2. with jslibs.eu_s2.
#BIT HACKY

rm -f .cmds.tmp

#Iterate over all SQLs and run them in BQ
find "$(pwd)" -name "*.sql" | sort  -z |while read fname; do
  echo "$fname"
  DIR=$(dirname "${fname}")
  libname=$(echo $DIR | sed -e 's;.*\/;;')
  file_name=$(basename "${fname}")
  function_name="${file_name%.*}"

  #we iterate over the regions to update or create all functions in the different regions
  for reg in "${regions[@]}"
  do
    if [[ "$reg" == "default_us" ]];
    then
      datasetname="${libname}"
    else
      datasetname="${reg}_${libname}"
    fi

    datasetname=$(echo "$datasetname" | sed -r 's/-/_/g')

    fn="blis-jslibs.${datasetname}.${function_name}"
    tmpfile=".${fn}.sql.tmp"

    echo "CREATING OR UPDATING ${fn}"

    sed "s/[\`]*jslibs\.\([^.]*\)\.\([^(\`]*\)[\`]*/\`blis-jslibs.${datasetname}.\2\`/g" $fname > $tmpfile
    sed -i "s/bigquery-jslibs/blis-bigquery-jslibs/g" $tmpfile

    echo "bq --project_id=\"$projectid\" --location=\"$region\" query --use_legacy_sql=false --flagfile=$tmpfile && rm $tmpfile" >> .cmds.tmp

  done
done

cat .cmds.tmp | xargs -I{} -n 1 -P 10 /bin/bash -c "{}"

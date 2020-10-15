#!/bin/bash

rgw_host=$(oc -n openshift-storage get route rgw -o json | jq -r '.status.ingress[0].host')
noobaa_host=$(oc -n openshift-storage get route s3 -o json | jq -r '.status.ingress[0].host')

for obc in example-noobaa example-rgw; do
	echo '########################################'
	echo $obc
	echo '########################################'

	awsdir=aws-$obc
	service=${obc#example-}
	hostvar="${service}_host"

	echo "  creating obc"
	oc apply -f "obc-${service}.yml"

	echo "  waiting for secret"
	while :; do
		oc get secret $obc > /dev/null 2>&1 && break
		sleep 1
	done

	mkdir -p $awsdir

	oc get secret $obc -o json | jq .data > $awsdir/secret.json
	oc get configmap $obc -o json | jq .data > $awsdir/config.json
	creds=( $(jq -r 'map(@base64d)[]' $awsdir/secret.json) )
	bucket_name=$(jq -r .BUCKET_NAME $awsdir/config.json)
	bucket_host=${!hostvar}

	cat > $awsdir/credentials <<-EOF
	[default]
	aws_access_key_id=${creds[0]}
	aws_secret_access_key=${creds[1]}

	# bucket_host = ${bucket_host}
	EOF

	sed "s/BUCKET_NAME/$bucket_name/g" policy.json > $awsdir/policy.json

	fqawsdir=$(readlink -f $awsdir)

	echo "  upload file to bucket before setting policy"
	podman run -v $fqawsdir:/root/.aws \
		-v $PWD/files:/data -w /data \
		amazon/aws-cli s3 --endpoint-url https://${bucket_host} \
		cp file1.txt s3://${bucket_name}

	echo "  read object before setting policy"
	if ! curl -sf https://${bucket_host}/${bucket_name}/file1.txt > /dev/null; then
		echo "  read failed (expected)"
	else
		echo "  read worked...what?"
	fi

	echo "  setting bucket policy"
	podman run -v $fqawsdir:/root/.aws \
		amazon/aws-cli s3api --endpoint-url https://${bucket_host} \
		put-bucket-policy --bucket $bucket_name \
		--policy "$(jq -c . $awsdir/policy.json)"

	echo "  setting bucket acl"
	podman run -v $fqawsdir:/root/.aws \
		amazon/aws-cli s3api --endpoint-url https://${bucket_host} \
		put-bucket-acl --bucket $bucket_name \
		--acl public-read

	echo "  upload file to bucket after setting policy"
	podman run -v $fqawsdir:/root/.aws \
		-v $PWD/files:/data -w /data \
		amazon/aws-cli s3 --endpoint-url https://${bucket_host} \
		cp file2.txt s3://${bucket_name}

	for obj in file1.txt file2.txt; do
		objurl="https://${bucket_host}/${bucket_name}/${obj}"

		echo "  read object $obj after setting policy"
		echo "  url: $objurl"
		if ! curl -sf "$objurl" > /dev/null; then
			echo "  read failed. sadness!"
		else
			echo "  read worked. yay!"
		fi
	done

done

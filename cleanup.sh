#!/bin/bash

for obc in example-noobaa example-rgw; do
	oc delete obc $obc
done

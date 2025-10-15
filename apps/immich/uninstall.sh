#!/bin/bash

helm ls --namespace immich
helm delete --namespace immich immich

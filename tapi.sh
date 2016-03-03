#!/bin/bash

# tAPI
# Copyright 2016 City of Helsinki
# Authors
#   Timo Tuominen <tituomin@gmail.com>
#
# Licensed under BSD
# (see LICENSE file)
#
# Includes deep_equal.py, included as permitted by the license,
# Copyright (c) 2010-2013 Samuel Sutch [samuel.sutch@gmail.com]


function tapi-help () {
    cat <<EOF

Welcome to the API testing tool tAPI.
==========================================

The following commands are at your disposal.
They require a server log file in Common Log Format.
Type tapi-help<enter> for this help.

== Starting up

Before using the tool, load the configuration for
a specific API using the command tapi-load. You
can initialize a new configuration file for an
API using tapi-init.

  tapi-init [settings-file]
    Initialize a new configuration file from a template.

  tapi-load [settings-file]
    Load the configuration for an API from a settings file.

== General instructions

Most of the API testing commands take as arguments
the server log file name and the amount of URLs
to test (by frequency of requests in the server log).

Since eg. sorting a large log file by frequency is expensive,
the results for expensive operations are stored in files
named cache.*

== Testing an API

1. Look for failing URLs

  tapi-fail LOGFILE COUNT [RESET]
    Display the URLs which return an HTTP status code denoting an error.
    Since the whole test might take a long time, you can re-check only
    the failing URLs (stored in a cache file) using tapi-recheck.
    Also, re-running the same tapi-fail command will show the results
    from the cache. Run tapi-fail LOGFILE COUNT reset to clear the cache.

  tapi-recheck LOGFILE COUNT
    After running tapi-fail, you can make changes in the API implementation
    and check if the failures found with tapi-fail have been resolved. This
    will save time since it only rechecks the previously failed URLs.

  tapi-debug LOGFILE COUNT
    This command also uses the cached results of the previous
    tapi-fail run. For each failing URL you can use the web
    browser to load the debug page of the failing URL.

2. Compare API response contents as JSON

  tapi-diff LOGFILE COUNT TAG1 TAG2
    Compare the JSON contents returned by two different versions
    of the API implementation.

    This command runs in two passes. Give a descriptive name TAG1
    for the API version run in the first pass, and TAG2 for the
    API version run in the second pass.

3. Measure API response time

  tapi-time LOGFILE COUNT
    Display the response time for the top count URLs in the log file.

== Utility functions

  tapi-top LOGFILE COUNT
    Display the top count urls by frequency in the log file.

  tapi-uniq LOGFILE
    Count the ratio of unique URLs / total amount of URLs in the log.
    Useful (?) for caching behaviour analysis.


EOF
}

# UTILITIES

function __extract_urls () {
    local logfile=$1
    zcat -f $logfile \
        | egrep -o '"GET [^ ]+' \
        | egrep -o "$BASE_URL/[^ ]+"
}

function __blacklist_urls () {
    local blacklist_file=$1
    egrep -v -f $blacklist_file
}

function __sort_urls () {
    local logfile=$1
    local checksum=($(md5sum $logfile))
    local cachefile="cache.sort_urls.$logfile.$checksum"
    if [ ! -f $cachefile ]
    then
        sort | uniq -c | sort -n >$cachefile
    fi
    cat $cachefile
}

function __top_urls () {
    local logfile=$1
    local count=$2
    __extract_urls $logfile | __sort_urls $logfile | tail -n $count
}

function __blacklisted_urls () {
    local logfile=$1
    __extract_urls $logfile | __blacklist_urls $BLACKLIST_FILE | __sort_urls
}

function __localize_urls () {
    sed -re "s|^.*$BASE_URL|$1|"
}

function __output_failure () {
    local url=$1
    curl -H "Host: $API_HOSTNAME" -o /dev/null -s --fail "$url" \
        || curl -H "Host: $API_HOSTNAME" -o /dev/null -s -w "%{http_code} $url\n" "$url"
}

function distribution () {
    local logfile=$1
    __blacklisted_urls $logfile | egrep -o '^ +[0-9]+' \
        | while read n; do echo $n; done
}

function flush_memcached () {
    echo "flush_all" | nc localhost 11211
}



# MAIN COMMAND-LINE ORIENTED FUNCTIONS

function tapi-uniq () {
    local totalp=$(mktemp)
    local uniqp=$(mktemp)
    local filename=$1
    __extract_urls $1 \
        | __blacklist_urls $BLACKLIST_FILE \
        | tee >(wc --lines >$totalp) \
        | sort | uniq | wc --lines >$uniqp
    read total <$totalp
    read unique <$uniqp
    local factor=$(echo "scale=3; $unique/$total" | bc)
    echo "unique $unique of total $total -> ratio $factor"
    rm $totalp
    rm $uniqp
}

function tapi-top () {
    local logfile=$1
    local count=$2
    local local_baseurl=$3
    __top_urls $logfile $count | __localize_urls $local_baseurl
}

function tapi-time () {
    export TIMEFORMAT='%3R'
    local logfile=$1
    local count=$2
    local urls=$(mktemp)
    tapi-top $logfile $count $LOCAL_URL | __blacklist_urls $BLACKLIST_FILE >$urls
    cat $urls |
        while read url
        do
            realtime=$( { \
                time curl -H "Host: $API_HOSTNAME" -o /dev/null -s --fail "$url" \
                || curl -H "Host: $API_HOSTNAME" -o /dev/null -s -w "HTTP FAILURE STATUS %{http_code}" "$url" ; \
            } 2>&1 )
            echo "$realtime $url"
        done
    unset TIMEFORMAT
    rm $urls
}

function tapi-fail () {
    local filename=$1
    local count=$2
    local reset=$3
    local checksum=($(md5sum $filename))
    local cachefile="cache.tapi-fail.$filename.$checksum.$count"
    [ ! -z "$reset" ] && [ -f $cachefile ] && rm "$cachefile"
    if [ ! -f $cachefile ]
    then
        tapi-top $filename $count $DEBUG_URL |\
            while read url
            do
                __output_failure $url
            done >$cachefile
    fi
    cat $cachefile
}

function tapi-recheck () {
    local logfile=$1
    local count=$2
    tapi-fail $logfile $count | awk '{print $2}' | \
        while read url
        do
            curl -H "Host: $API_HOSTNAME" -o /dev/null -s -w "%{http_code} $url\n" "$url"
        done
}

function tapi-debug () {
    local logfile=$1
    local count=$2
    tapi-fail $logfile $count | awk '{print $2}' |\
    while read url
    do
        ( read -p "Type d [enter] to debug $url in chrome: " yn
          case $yn in
            [Dd]* ) google-chrome --new-window $url; break;;
            * ) break ;;
          esac
        ) </dev/tty
    done
}

function tapi-diff () {
    local logfile=$1
    local count=$2
    local cachefile_left="tapi-diff.$3"
    local cachefile_right="tapi-diff.$4"
    local cachefile=$cachefile_right
    local ignore_fields=$5
    if [ ! -f $cachefile_left ]
    then
        echo "Generating contents for tag $3."
        cachefile=$cachefile_left
    elif [ ! -f $cachefile_right ]
    then
        echo "Generating contents for tag $4."
    fi
    if [ ! -f $cachefile ]
    then
        tapi-top $logfile $count $LOCAL_URL |\
            while read url
            do
                echo -ne "\n\nURL:\n$url\nCONTENTS:\n"
                curl -H "Host: $API_HOSTNAME" $url -s
            done >$cachefile ;
        echo "Done."
    fi
    if [ -f $cachefile_left -a -f $cachefile_right ]
    then
        echo "Both files ready, comparing."
        json_diff.py $cachefile_left $cachefile_right $ignore_fields
    else
        echo "Switch release and run again."
    fi
}

function tapi-init () {
    local filename=$1
    [ -z "$1" ] && filename="tapi.conf"
    echo -e "Initialized config file $filename\n"
    cat >$filename <<EOF
# Configuration file for tAPI REST JSON API testing tool.

# The API might require a specific Host delivered in the HTTP headers
# example: API_HOSTAME='api.server.com'
#
API_HOSTNAME=

# The base url of the API in production.
# This should correspond to the entries
# in the log file used. This part of
# the URLs will be transformed into
# LOCAL_URL (see below).
# example: BASE_URL='http://api.server.com/servicename'
#
BASE_URL=

# When testing the API, the production log
# URLs should be transformed into corresponding
# test deployment versions. Typically these
# are on localhost.
# example: LOCAL_URL='http://localhost:8000'
#
LOCAL_URL=

# If you have deployed a separate local API
# implementation in debugging mode
# (for inspecting stack traces etc.),
# put the corresponding base URL here. If left commented
# out, DEBUG_URL is the same as LOCAL_URL.
# example: DEBUG_URL='http://localhost:8001'
#
#DEBUG_URL=


# File containing extended regular expressions
# to filter out when testing.
# example: BLACKLIST_FILE=/dev/null
#
BLACKLIST_FILE=/dev/null

EOF
}

function tapi-load () {
    local settings_file=$1
    source $settings_file
    [ -z $DEBUG_URL ] && DEBUG_URL=$LOCAL_URL
}

tapi-help

DIR="$( cd "$( dirname "${BASH_SOURCE[@]}" )" && pwd )"
PATH=$PATH:$DIR

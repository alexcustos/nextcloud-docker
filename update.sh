#!/bin/bash
set -eo pipefail

declare -A php_version=(
	[default]='7.1'
)

declare -A cmd=(
	[apache]='apache2-foreground'
	[fpm]='php-fpm'
	[fpm-alpine]='php-fpm'
)

declare -A base=(
	[apache]='debian'
	[fpm]='debian'
	[fpm-alpine]='alpine'
)

declare -A extras=(
	[apache]='\nRUN a2enmod rewrite remoteip ;\\\n    {\\\n     echo RemoteIPHeader X-Real-IP ;\\\n     echo RemoteIPTrustedProxy 10.0.0.0/8 ;\\\n     echo RemoteIPTrustedProxy 172.16.0.0/12 ;\\\n     echo RemoteIPTrustedProxy 192.168.0.0/16 ;\\\n    } > /etc/apache2/conf-available/remoteip.conf;\\\n    a2enconf remoteip'
	[fpm]=''
	[fpm-alpine]=''
)

declare -A pecl_versions=(
	[APCu]='5.1.11'
	[memcached]='3.0.4'
	[redis]='3.1.6'
)

variants=(
	apache
)

min_version='13.0'

# version_greater_or_equal A B returns whether A >= B
function version_greater_or_equal() {
	[[ "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1" || "$1" == "$2" ]];
}

# checks if the the rc is already released
function check_released() {
	printf '%s\n' "${fullversions[@]}" | grep -qE "^$( echo "$1" | grep -oE '[[:digit:]]+(\.[[:digit:]]+){2}' )"
}

travisEnv=
lawless_base="https://download.lawless.cloud/server/releases"

function create_variant() {
	dir="$1/$variant"

	# Create the version+variant directory with a Dockerfile.
	mkdir -p "$dir"

        template="Dockerfile-${base[$variant]}.template"
        echo "# DO NOT EDIT: created by update.sh from $template" > "$dir/Dockerfile"
	cat "$template" >> "$dir/Dockerfile"

	echo "updating $fullversion [$1] $variant"

	# Replace the variables.
	sed -ri -e '
		s/%%PHP_VERSION%%/'"${php_version[$version]-${php_version[default]}}"'/g;
		s/%%VARIANT%%/'"$variant"'/g;
		s/%%VERSION%%/'"$fullversion"'/g;
		s~%%BASE_DOWNLOAD_URL%%~'"$lawless_base"'~g;
		s/%%CMD%%/'"${cmd[$variant]}"'/g;
		s|%%VARIANT_EXTRAS%%|'"${extras[$variant]}"'|g;
		s/%%APCU_VERSION%%/'"${pecl_versions[APCu]}"'/g;
		s/%%MEMCACHED_VERSION%%/'"${pecl_versions[memcached]}"'/g;
		s/%%REDIS_VERSION%%/'"${pecl_versions[redis]}"'/g;
	' "$dir/Dockerfile"

	# Copy the shell scripts
	for name in entrypoint cron; do
		cp "docker-$name.sh" "$dir/$name.sh"
	done

	# Copy the config directory
	cp -rT .config "$dir/config"

	# Remove Apache config if we're not an Apache variant.
	if [ "$variant" != "apache" ]; then
		rm "$dir/config/apache-pretty-urls.config.php"
	fi

	for arch in amd64; do
		travisEnv='\n    - env: VERSION='"$1"' VARIANT='"$variant"' ARCH='"$arch$travisEnv"
	done
}

find . -maxdepth 1 -type d -regextype sed -regex '\./[[:digit:]]\+\.[[:digit:]]\+\(-rc\)\?' -exec rm -r '{}' \;

fullversions=( $( curl -fsSL "$lawless_base" |tac|tac| \
	grep -oE 'lawless-[[:digit:]]+(\.[[:digit:]]+){2}' | \
	grep -oE '[[:digit:]]+(\.[[:digit:]]+){2}' | \
	sort -urV ) )
versions=( $( printf '%s\n' "${fullversions[@]}" | cut -d. -f1-2 | sort -urV ) )
for version in "${versions[@]}"; do
	fullversion="$( printf '%s\n' "${fullversions[@]}" | grep -E "^$version" | head -1 )"

	if version_greater_or_equal "$version" "$min_version"; then

		for variant in "${variants[@]}"; do

			create_variant "$version"
		done
	fi
done

# replace the fist '-' with ' '
travisEnv="$(echo "$travisEnv" | sed '0,/-/{s/-/ /}')"

# update .travis.yml
travis="$(awk -v 'RS=\n\n' '$1 == "-" && $2 == "stage:" && $3 == "test" && $4 == "images" { $0 = "    - stage: test images'"$travisEnv"'" } { printf "%s%s", $0, RS }' .travis.yml)"
echo "$travis"  > .travis.yml

# syntax=docker/dockerfile:1.3-labs
FROM docker:19.03.4

RUN apk update \
  && apk upgrade \
  && apk add --no-cache --update python py-pip coreutils bash \
  && rm -rf /var/cache/apk/* \
  && pip install pyyaml==5.3.1 \
  && pip install -U awscli \
  && apk --purge -v del py-pip \
  && apk add docker-credential-ecr-login -X https://dl-cdn.alpinelinux.org/alpine/edge/community/ --allow-untrusted

RUN mkdir ~/.docker

RUN <<EOF
echo '{"credsStore": "ecr-login"}' >> ~/.docker/config.json
EOF

ADD entrypoint.sh /entrypoint.sh

RUN ["chmod", "+x", "/entrypoint.sh"]

ENTRYPOINT ["/entrypoint.sh"]

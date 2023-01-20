# syntax=docker/dockerfile:1.3-labs
FROM docker:20.10.22

ENV PYTHONUNBUFFERED=1

RUN apk update \
  && apk upgrade \
  && apk add --no-cache --update python3 coreutils bash \
  && ln -sf python3 /usr/bin/python \
  && rm -rf /var/cache/apk/*
#   && apk add docker-credential-ecr-login -X https://dl-cdn.alpinelinux.org/alpine/edge/community/ --allow-untrusted

RUN python3 -m ensurepip  \
  && ln -sf pip3 /usr/bin/pip

RUN pip install --no-cache --upgrade pip setuptools \
  && pip install pyyaml==5.3.1 \
  && pip install -U awscli

RUN mkdir /root/.docker
COPY ./config.json /root/.docker/config.json

ADD entrypoint.sh /entrypoint.sh

RUN ["chmod", "+x", "/entrypoint.sh"]

ENTRYPOINT ["/entrypoint.sh"]

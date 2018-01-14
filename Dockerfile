FROM debian:jessie
RUN apt-get update -qqy && apt-get install -qqy \
        curl \
        gcc \
        python-dev \
        python-setuptools \
        apt-transport-https \
        lsb-release \
        openssh-client \
        git \
        bash \
        jq \
        sshpass \
        openssh-client \
    && easy_install -U pip && \
    pip install -U crcmod python-dotenv pyyaml

VOLUME ["/pwd"]

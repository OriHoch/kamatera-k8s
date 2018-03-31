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
    pip install -U crcmod 'python-dotenv[cli]' pyyaml

VOLUME ["/pwd"]

COPY kamatera.sh /__kamatera/
COPY switch_environment.sh /__kamatera/
COPY connect.sh /__kamatera/
COPY kamatera_server_options.json /__kamatera/
COPY read_yaml.py /__kamatera/
COPY update_yaml.py /__kamatera/
ENTRYPOINT ["/__kamatera/kamatera.sh"]

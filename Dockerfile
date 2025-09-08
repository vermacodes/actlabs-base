FROM ubuntu:22.04

RUN mkdir /app
WORKDIR /app

ADD run.sh ./
ADD install_azure_cli.sh ./
ADD install_aro_extension.sh ./

RUN chmod +x ./run.sh
RUN ./run.sh
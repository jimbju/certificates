GOPATH=/root/go
make V=1 download
make V=1 GOFLAGS="" build
mkdir /opt/app/step-ca
mkdir --parents /opt/app/step-ca; mv bin /opt/app/step-ca
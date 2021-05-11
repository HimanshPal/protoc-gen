FROM ubuntu:20.04 as builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt -y update && \
        apt install -y build-essential autoconf libtool git pkg-config wget zlib1g-dev cmake \
        curl gnupg python3 python3-pip

ENV GRPC_VERSION=1.37.0 \
        OUTDIR=/out \
        PROTOC_GEN_GO_VERSION=1.26.0 \
        GRPC_GATEWAY_VERSION=1.14.1\
        GRPC_JAVA_VERSION=1.24.0 \
        GO_VERSION=1.16.3 \
        GOROOT=/usr/local/go \
        GOPATH=/go \
        PATH=/usr/local/go/bin/:$PATH

# add bazel apt repo and install bazel
# RUN curl -fsSL https://bazel.build/bazel-release.pub.gpg | gpg --dearmor > bazel.gpg && \
# 	mv bazel.gpg /etc/apt/trusted.gpg.d/ && \
# 	echo "deb [arch=amd64] https://storage.googleapis.com/bazel-apt stable jdk1.8" | tee /etc/apt/sources.list.d/bazel.list && \
# 	apt -y update && \
# 	apt install -y bazel-4.0.0 && \
# 	ln -s /usr/bin/bazel-4.0.0 /usr/bin/bazel

# Install Go
RUN mkdir /go && \
        cd /go && \
        wget https://dl.google.com/go/go${GO_VERSION}.linux-amd64.tar.gz && \
        tar -xvzf *.tar.gz && \
        mv go /usr/local/

# Build gRPC core
RUN git clone --depth 1 --recursive -b v${GRPC_VERSION} https://github.com/grpc/grpc.git /grpc && \
        cd grpc && \
        git submodule update --init && \
 	mkdir -p cmake/build && \
	cd cmake/build && \
	cmake ../.. \
		-DgRPC_INSTALL=ON \
		-DCMAKE_BUILD_TYPE=module \
		-DgRPC_ABSL_PROVIDER=module \
		-DgRPC_CARES_PROVIDER=module \
		-DgRPC_PROTOBUF_PROVIDER=module \
		-DgRPC_RE2_PROVIDER=module \
		-DgRPC_SSL_PROVIDER=module \
		-DgRPC_ZLIB_PROVIDER=module \
		-DBUILD_SHARED_LIBS=ON \
		-DCMAKE_INSTALL_PREFIX=${OUTDIR}/usr && \
	make && make install

# build gRPC Go compiler
# NOTE: currently using niether go install nor go get works when specifying specific
# package version
RUN go get google.golang.org/protobuf/cmd/protoc-gen-go \
        google.golang.org/grpc/cmd/protoc-gen-go-grpc
RUN cp ${GOPATH}/bin/protoc-gen-go ${GOPATH}/bin/protoc-gen-go-grpc ${OUTDIR}/usr/bin/

# Build gRPC Java compiler
RUN mkdir -p /grpc-java && \
    cd /grpc-java && \
    wget https://github.com/grpc/grpc-java/archive/v${GRPC_JAVA_VERSION}.tar.gz && \
    tar --strip 1 -C /grpc-java -xvzf *.tar.gz && \
    g++ \
        -I. -I/grpc/third_party/protobuf/src \
        /grpc-java/compiler/src/java_plugin/cpp/*.cpp \
	-L${OUTDIR}/usr/lib \
        -lprotoc -lprotobuf -lpthread --std=c++0x -s \
        -o protoc-gen-grpc-java && \
    install -Ds protoc-gen-grpc-java ${OUTDIR}/usr/bin/protoc-gen-grpc-java
 
# Install grpc-gateway
RUN mkdir -p /grpc-gateway && \
    cd /grpc-gateway && \
    wget https://github.com/grpc-ecosystem/grpc-gateway/archive/v${GRPC_GATEWAY_VERSION}.tar.gz && \
    tar --strip 1 -C /grpc-gateway -xvzf *.tar.gz && \
    cd /grpc-gateway && \
    go build -ldflags '-w -s' -o /grpc-gateway-out/protoc-gen-grpc-gateway ./protoc-gen-grpc-gateway && \
    go build -ldflags '-w -s' -o /grpc-gateway-out/protoc-gen-swagger ./protoc-gen-swagger && \
    install -Ds /grpc-gateway-out/protoc-gen-grpc-gateway ${OUTDIR}/usr/bin/ && \
    install -Ds /grpc-gateway-out/protoc-gen-swagger ${OUTDIR}/usr/bin/

########################
# Build final image
########################
FROM ubuntu:20.04

RUN apt-get -y update && apt-get install -y curl

COPY --from=builder /out/ /

# Add common base protos from google.protobuf and google.api namespaces
RUN mkdir -p /protobuf/google/protobuf && \
        for f in any duration descriptor empty struct timestamp wrappers; do \
        curl -L -o /protobuf/google/protobuf/${f}.proto https://raw.githubusercontent.com/google/protobuf/master/src/google/protobuf/${f}.proto; \
        done && \
        mkdir -p /protobuf/google/api && \
        for f in annotations http; do \
        curl -L -o /protobuf/google/api/${f}.proto https://raw.githubusercontent.com/grpc-ecosystem/grpc-gateway/master/third_party/googleapis/google/api/${f}.proto; \
        done && \
        chmod a+x /usr/bin/protoc

ENTRYPOINT ["/usr/bin/protoc"]

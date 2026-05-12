PORTNAME=	askgpt
DISTVERSION=	0.1.0
CATEGORIES=	sysutils

MAINTAINER=	ports@FreeBSD.org
COMMENT=	Small OpenAI Responses API shell client
WWW=		https://github.com/JamesElstone/AskGPT

LICENSE=	BSD3CLAUSE
LICENSE_FILE=	${WRKSRC}/LICENSE

RUN_DEPENDS=	curl:ftp/curl \
		jq:textproc/jq \
		ca_root_nss>0:security/ca_root_nss

USES=		shebangfix
USE_GITHUB=	yes
GH_ACCOUNT=	JamesElstone
GH_PROJECT=	AskGPT
GH_TAGNAME=	6575890ccbcca773862c41d6c166f6a03d740902

SHEBANG_FILES=	askgpt.sh

NO_ARCH=	yes
NO_BUILD=	yes

PLIST_FILES=	bin/askgpt
PORTDOCS=	README.md

OPTIONS_DEFINE=	DOCS

do-install:
	${INSTALL_SCRIPT} ${WRKSRC}/askgpt.sh ${STAGEDIR}${PREFIX}/bin/askgpt

do-install-DOCS-on:
	@${MKDIR} ${STAGEDIR}${DOCSDIR}
	${INSTALL_DATA} ${WRKSRC}/README.md ${STAGEDIR}${DOCSDIR}

.include <bsd.port.mk>

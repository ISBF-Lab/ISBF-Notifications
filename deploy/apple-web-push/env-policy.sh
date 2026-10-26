# Source this file before Unicorn inherits its environment.
# Presence (including an empty lowercase value) determines Ruby's prior value.
if [ "${no_proxy+x}" != x ]; then
  no_proxy=${NO_PROXY-}
fi
if [ "${NO_PROXY+x}" != x ]; then
  NO_PROXY=$no_proxy
fi

case ",$no_proxy," in
  *[[:space:],][wW][eE][bB].[pP][uU][sS][hH].[aA][pP][pP][lL][eE].[cC][oO][mM][[:space:],]*) ;;
  *) no_proxy=${no_proxy:+"$no_proxy,"}web.push.apple.com ;;
esac
case ",$NO_PROXY," in
  *[[:space:],][wW][eE][bB].[pP][uU][sS][hH].[aA][pP][pP][lL][eE].[cC][oO][mM][[:space:],]*) ;;
  *) NO_PROXY=${NO_PROXY:+"$NO_PROXY,"}web.push.apple.com ;;
esac
export no_proxy NO_PROXY

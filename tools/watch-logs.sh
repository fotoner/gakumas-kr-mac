#!/bin/bash
# GakumasLocalify dylib 관련 로그만 스트리밍
log stream \
  --predicate 'processImagePath CONTAINS "idolmaster_gakuen" AND (senderImagePath CONTAINS "GakumasLocalifyIOS_KR" OR eventMessage CONTAINS "GakumasLocal" OR eventMessage CONTAINS "Translation" OR eventMessage CONTAINS "SetText")' \
  --info --debug --style compact

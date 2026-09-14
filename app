#!/bin/bash

# SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd ) #"
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")") #"
LOG_LEVEL=debug
LOG_FILE=/var/log/cir_db.log

cd $SCRIPT_DIR

. ENV.sh 

case $1 in
    start)
      elixir --sname cir_db -S mix run --no-halt -- --log-file $LOG_FILE --log-level $LOG_LEVEL
      ;;

    stop)
      (elixir --sname update --rpc-eval cir_db "System.halt(0)" ; exit 0)
      ;;

    console)
      iex --remsh cir_db --sname console
      ;;

    dev)
      iex -S mix run --no-halt -- --log-file $LOG_FILE --log-level $LOG_LEVEL
      ;;

    restart)
      #elixir --sname update --rpc-eval spi_acs@localhost "Reload.doit()"
      ${BASH_SOURCE[0]} stop
      ${BASH_SOURCE[0]} start
      ;;

    log)
      tail -f $LOG_FILE
      ;;
      
    *) 
      echo "Usage:"
      echo 
      echo " ${BASH_SOURCE[0]} (start|stop|console|restart|log)"
      ;;
esac 


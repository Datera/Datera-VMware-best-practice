########
########  Script Constants
########

## Storage Values

    $DateraIscsiQueueDepth = '16' # Datera recommends 16
    $DateraLunQueueFullSampleSize = '32'
    $DateraLunQueueFullThreshold = '4'
    # Reference https://kb.vmware.com/s/article/1008113
## Email

    $SMTP_RELAY = "smtp.example.com"
    $SMTP_FROM = "datera-alerts@example.com"
    $SMTP_TO = "alerts@example.com"
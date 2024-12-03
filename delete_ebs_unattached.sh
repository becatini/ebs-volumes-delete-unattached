#!/bin/bash

DIR="${HOME}/repo/ebs-volumes_unattached"
# Check if the directory exists
if [ ! -d "$DIR" ]; then
  mkdir -p "$DIR"
fi

VOLUMES_CSV="${DIR}/ebs_volumes_unattached.csv"
VOLUMES_CSV_FORMATED="${DIR}/ebs_volumes_unattached_formated.csv"

CURRENT_DATE=$(date +%Y-%m-%d)
# Get the current date in seconds
CURRENT_DATE_SEC=$(date +%s)

LOG="${DIR}/LOG_delete_unattached_volumes_${CURRENT_DATE}.txt"
DELETED_VOLUMES="${DIR}/deleted_volumes_${CURRENT_DATE}.txt"
ACCOUNT_OUTPUT="${DIR}/accounts.txt"

# Delete the first line and remove everything after the 4o comma
sed '1d; s/\([^,]*,[^,]*,[^,]*,[^,]*\).*/\1/' "$VOLUMES_CSV" > "$VOLUMES_CSV_FORMATED"

# Set the threshold for unattached time (in days)
DAYS_THRESHOLD=45
# Set the threshold for unattached time (in seconds)
SECONDS_THRESHOLD=$((DAYS_THRESHOLD * 24 * 60 * 60))

# Clean up files
> $LOG
> $DELETED_VOLUMES
> $ACCOUNT_OUTPUT

echo "" | tee -a $LOG
echo "Current date --> $(date)" | tee -a $LOG
echo "" | tee -a $LOG

while IFS=',' read -r ACCOUNT REGION VOLUME SIZE
do
	# Skip empty lines
  	if [[ -z "$ACCOUNT" || -z "$REGION" || -z "$VOLUME" || -z "$SIZE" ]]; then
    	continue
  	fi	
	
	# Check if account changed
  	if [[ "$ACCOUNT" != "$CURRENT_ACCOUNT" ]]; then    	
    	
    	echo "+------------------------------+" | tee -a $LOG
    	echo "Processing account: $ACCOUNT"     | tee -a $LOG
    	echo "+------------------------------+" | tee -a $LOG
           	   	
		# Unset assume role credentials
    	unset AWS_ACCESS_KEY_ID
    	unset AWS_SECRET_ACCESS_KEY
    	unset AWS_SESSION_TOKEN
		
		# Assume role
		ROLEARN="arn:aws:iam::${ACCOUNT}:role/Terraform"
    	ASSUME_ROLE=$(aws sts assume-role \
        	            --role-arn $ROLEARN \
            	        --role-session-name AssumeRoleSession \
                	    --profile $myprofile \
                    	--query 'Credentials.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey,SessionToken:SessionToken}')
    	
		if [[ -z "$ASSUME_ROLE" ]]; then # String NULL
		    echo "$ACCOUNT NOK" >> $ACCOUNT_OUTPUT
    		echo "Access denied" | tee -a $LOG
			echo "" | tee -a $LOG
    		continue # Skip to the next account
		else		
			echo "$ACCOUNT OK" >> $ACCOUNT_OUTPUT
			# Set up the credentials
    		export AWS_ACCESS_KEY_ID=$(echo $ASSUME_ROLE | jq -r '.AccessKeyId')
    		export AWS_SECRET_ACCESS_KEY=$(echo $ASSUME_ROLE | jq -r '.SecretAccessKey')
    		export AWS_SESSION_TOKEN=$(echo $ASSUME_ROLE | jq -r '.SessionToken')
		fi
			
		# Update the current account being processed
    	CURRENT_ACCOUNT="$ACCOUNT"
	fi

	# Check if we are processing a new region
  	if [[ "$REGION" != "$CURRENT_REGION" ]]; then    	
		# Update the current region being processed
    	CURRENT_REGION="$REGION"
		echo "Region: $REGION" | tee -a $LOG
		echo "---" | tee -a $LOG
	fi

	# Check CloudTrail for the DetachVolume event
	DETACH_TIME=$(aws cloudtrail lookup-events \
					--region $REGION \
					--lookup-attributes AttributeKey=ResourceName,AttributeValue=$VOLUME \
					--query "Events[?EventName=='DetachVolume'] | [0].EventTime" \
					--output text | sort -u)	
	
	if [ "$DETACH_TIME" != "None" ] ; then
		# Convert detach time to seconds since the epoch
		DETACH_DATE_SEC=$(date -d "$DETACH_TIME" +%s)
		# Calculate the time difference
		TIME_DIFF=$((CURRENT_DATE_SEC - DETACH_DATE_SEC))
		# Check if the volume has been unattached for more than the threshold
		
		if [ "$TIME_DIFF" -ge "$SECONDS_THRESHOLD" ]; then
			echo "$VOLUME >> $DETACH_TIME >> Unattached for more than $DAYS_THRESHOLD days. Deleting volume..." | tee -a $LOG
			echo "" | tee -a $LOG
			echo "${ACCOUNT},${REGION},${VOLUME},${SIZE}" >> $DELETED_VOLUMES
			#aws ec2 delete-volume $VOLUME
		else
			echo "$VOLUME << $DETACH_TIME << Unattached for less than $DAYS_THRESHOLD days. Won't be deleted." | tee -a $LOG
			echo "" | tee -a $LOG
			echo "${ACCOUNT},${REGION},${VOLUME},${SIZE}" >> $DELETED_VOLUMES
		fi
	else
		echo "$VOLUME <> No DetachVolume event in CloudTrail logs. Deleting volume..." | tee -a $LOG
		echo "" | tee -a $LOG
		echo "${ACCOUNT},${REGION},${VOLUME},${SIZE}" >> $DELETED_VOLUMES
		#aws ec2 delete-volume $VOLUME
	fi
			
done < "$VOLUMES_CSV_FORMATED"

# Amount in Gigs saved
# VOLUME_GIG=$(awk -F',' '{sum += $4} END {print sum}' "deleted_volumes_${CURRENT_DATE}.txt")
# Total volumes deleted
# VOLUME_COUNT=$(wc -l < "deleted_volumes_${CURRENT_DATE}.txt")

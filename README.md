# aws-ssm-instance-private
Script that creates an EC2 in a private subnet and configures access via AWS Systems Manager. Prepared for educational purposes.


## Infrastructure diagram

![infrastructure-diagram](https://github.com/charlos/aws-ssm-instance-private/assets/1676608/a64d0b3b-9617-401c-9586-a03c5264284c)

### *Must exist beforehand
- VPC
- Private subnet 
- Public subnet
- Bucket S3

## Commands

* Create infrastructure
```bash
bash instance-private-with-ssm.sh --private-subnet-id=subnetID --public-subnet-id=subnetID
```

* Delete infrastructure
```bash
bash instance-private-with-ssm.sh --private-subnet-id=subnetID --public-subnet-id=subnetID --delete
```

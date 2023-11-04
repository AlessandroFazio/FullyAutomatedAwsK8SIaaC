# Use the AWS Lambda base image for Python 3.8
FROM public.ecr.aws/lambda/python:3.8

# install dependencies
RUN yum -y groupinstall "Development Tools"
RUN yum -y update
RUN echo -e "\
[pgdg11] \n\
name            = PostgreSQL 11 $releasever - $basearch \n\
baseurl         = https://download.postgresql.org/pub/repos/yum/11/redhat/rhel-7.5-x86_64 \n\
enabled         = 1 \n\
gpgcheck        = 0 \n\
" > /etc/yum.repos.d/pgdg.repo

RUN sed "s/rhel-\$releasever-\$basearch/rhel-7.5-x86_64/g" "/etc/yum.repos.d/pgdg.repo"
RUN yum groupinstall "PostgreSQL Database Server 11 PGDG" -y
RUN yum install postgresql11 postgresql11-server -y
COPY systemctl.py /usr/bin/systemctl
RUN chmod a+x /usr/bin/systemctl
RUN systemctl enable postgresql11
RUN systemctl start postgresql11
RUN export PATH=/usr/pgsql-11/bin/psql:$PATH

# Copy your function code
COPY dbbootstrap.py /var/task

# Set the CMD to your handler (could also be done as a parameter override outside of the Dockerfile)
CMD [ "dbbootstrap.handler" ]